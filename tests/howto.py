"""The commands the how-to guides show with their output."""
from pathlib import Path
import re
import textwrap

HOWTO = Path(__file__).resolve().parents[1] / "docs" / "orgmode" / "howto"

# A one-line bash block, then at once an example block: the command's output.
SHOWN = re.compile(r"^( *)#\+begin_src bash\n\1([^\n]*)\n\1#\+end_src\n\n\1#\+begin_example\n(.*?)^\1#\+end_example\n",
                   re.M | re.S)


def shown(name):
    """Each one-line command the how-to NAME (write-a-site-file for
    write-a-site-file.org) shows with its output, and that output."""
    text = (HOWTO / f"{name}.org").read_text()
    return [(m.group(2), textwrap.dedent(m.group(3))) for m in SHOWN.finditer(text)]
