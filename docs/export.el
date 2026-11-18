;;; export.el --- Export docs/orgmode to the MyST pages Sphinx builds  -*- lexical-binding: t; -*-

;; The pages under docs/ that have an Org source are written from it:
;; docs/orgmode/PART/NAME.org becomes docs/PART/NAME.md.  Edit the Org
;; file and run, from the repository:
;;
;;   emacs --batch -l docs/export.el
;;
;; EB_LOCAL_DOCS_OUT names another directory to write into, which is how
;; the tests compare a fresh export with the committed pages.  Only Org's
;; own Markdown backend is used, so any Emacs 29 can run this.

;;; Code:

(require 'ox-md)
(require 'subr-x)

(defconst eb-local-docs-root
  (file-name-directory (or load-file-name buffer-file-name))
  "The docs/ directory.")

(defun eb-local-docs--fence (lang code)
  "CODE in a fenced block, tagged LANG when there is one."
  (format "```%s\n%s```\n" (or lang "") (org-remove-indentation code)))

(defun eb-local-docs--src-block (src-block _contents info)
  (eb-local-docs--fence (org-element-property :language src-block)
                        (org-export-format-code-default src-block info)))

(defun eb-local-docs--example-block (example-block _contents info)
  (eb-local-docs--fence "text" (org-export-format-code-default example-block info)))

(defun eb-local-docs--fixed-width (fixed-width _contents _info)
  (eb-local-docs--fence "text" (org-element-property :value fixed-width)))

(defun eb-local-docs--table-cell (_cell contents _info)
  (replace-regexp-in-string "|" "\\\\|" (string-trim (or contents ""))))

(defun eb-local-docs--table-row (row _contents info)
  "A pipe-table row, and the separator after the header, or after the
first row of a table that has none."
  (unless (eq (org-element-property :type row) 'rule)
    (let* ((cells (org-element-contents row))
           (table (org-export-get-parent-table row))
           (header (or (org-export-table-row-ends-header-p row info)
                       (and (not (org-export-table-has-header-p table info))
                            (= (org-export-table-row-number row info) 0)))))
      (concat "| "
              (string-join (mapcar (lambda (cell) (org-export-data cell info)) cells) " | ")
              " |\n"
              (when header
                (concat "|" (string-join (make-list (length cells) "---") "|") "|\n"))))))

(defun eb-local-docs--table (_table contents _info)
  "The rows, without the blank lines Org's Markdown puts between elements."
  (replace-regexp-in-string "\n\\(?:[ \t]*\n\\)+" "\n" contents))

(defun eb-local-docs--item (item contents info)
  "A description item as a MyST definition, anything else as Org's Markdown has it."
  (let ((tag (org-element-property :tag item)))
    (if (not tag)
        (org-md-item item contents info)
      (format "%s\n: %s\n" (org-export-data tag info)
              (replace-regexp-in-string "\n\\(.\\)" "\n  \\1" (string-trim (or contents "")))))))

(defun eb-local-docs--plain-list (plain-list contents info)
  "A description list as definitions with a blank line between them."
  (if (eq (org-element-property :type plain-list) 'descriptive)
      (mapconcat (lambda (item) (org-export-data item info))
                 (org-element-contents plain-list) "\n")
    (org-md-plain-list plain-list contents info)))

(defun eb-local-docs--link (link desc info)
  "Org's Markdown link, keeping a #anchor search option on a file link."
  (let ((search (org-element-property :search-option link)))
    (if (and (string= (org-element-property :type link) "file")
             search (string-prefix-p "#" search))
        (let ((path (org-element-property :path link)))
          (when (string-suffix-p ".org" path)
            (setq path (concat (file-name-sans-extension path) ".md")))
          (format "[%s](%s%s)" (or desc path) path search))
      (org-md-link link desc info))))

(defun eb-local-docs--template (contents info)
  "The page: where it comes from, its title, then its contents."
  (format "<!-- Generated from docs/orgmode/%s by docs/export.el; edit that file. -->\n\n# %s\n\n%s"
          (plist-get info :eb-local-source)
          (org-export-data (plist-get info :title) info)
          contents))

(defun eb-local-docs--tidy (text _backend _info)
  "One blank line between blocks, no blank at the end of a line, and a
single newline at the end.  Org's Markdown indents the empty lines of a
list item, such as those around a block in a numbered step."
  (let ((text (replace-regexp-in-string "[ \t]+$" "" text)))
    (concat (string-trim (replace-regexp-in-string "\n\n\n+" "\n\n" text)) "\n")))

(org-export-define-derived-backend 'eb-local-myst 'md
  :translate-alist '((src-block . eb-local-docs--src-block)
                     (example-block . eb-local-docs--example-block)
                     (fixed-width . eb-local-docs--fixed-width)
                     (table . eb-local-docs--table)
                     (table-row . eb-local-docs--table-row)
                     (table-cell . eb-local-docs--table-cell)
                     (item . eb-local-docs--item)
                     (plain-list . eb-local-docs--plain-list)
                     (link . eb-local-docs--link)
                     (template . eb-local-docs--template))
  :filters-alist '((:filter-final-output . eb-local-docs--tidy)))

(defun eb-local-docs-export (out)
  "Write each Org page under docs/orgmode as MyST under OUT."
  (let ((src (expand-file-name "orgmode" eb-local-docs-root))
        ;; With Babel, an inline source block exports its results, and a
        ;; batch export runs nothing, so src_sh{...} would come out empty.
        (org-export-use-babel nil)
        (org-md-headline-style 'atx)
        (org-md-toplevel-hlevel 2)
        (org-export-with-toc nil)
        (org-export-with-section-numbers nil)
        (org-export-with-author nil)
        (org-export-with-date nil)
        (org-export-with-sub-superscripts '{})
        (org-export-time-stamp-file nil)
        (make-backup-files nil))
    (dolist (org (directory-files-recursively src "\\.org\\'"))
      (let* ((rel (file-relative-name org src))
             (md (expand-file-name (concat (file-name-sans-extension rel) ".md") out)))
        (make-directory (file-name-directory md) t)
        (with-temp-buffer
          (insert-file-contents org)
          (setq default-directory (file-name-directory org))
          (org-mode)
          (let ((text (org-export-as 'eb-local-myst nil nil nil
                                     (list :eb-local-source rel))))
            (with-temp-file md (insert text))))
        (message "%s" md)))))

(when noninteractive
  (let ((out (getenv "EB_LOCAL_DOCS_OUT")))
    (eb-local-docs-export
     (if (and out (not (string-empty-p out))) out eb-local-docs-root))))

;;; export.el ends here
