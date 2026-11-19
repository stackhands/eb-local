"""Lifecycle checks for shell code printed by ``eb-local dev``."""

import unittest

from test_storage import StorageFixture


class DevShellLifecycle(StorageFixture):
    """Exercise successive dev-shell changes in the same caller."""


if __name__ == "__main__":
    unittest.main()
