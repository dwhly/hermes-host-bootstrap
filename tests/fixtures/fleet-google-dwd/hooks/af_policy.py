"""Fake af_policy for tests: SYSTEM_READ_SUBJECTS copied from h-af /root/.hermes/hooks/af_policy.py:150
(2026-11-23). The check_* functions record calls and raise when the test sets DENY."""
SYSTEM_READ_SUBJECTS = {"ncohn@amforge.com", "dhorn@amforge.com", "afedirka@amforge.com"}
CALLS = []
DENY = set()


def _chk(name, subject):
    CALLS.append((name, subject))
    if name in DENY:
        raise PermissionError(f"{name} denied for {subject}")


def check_dan_mailbox(subject, session_id=None):
    _chk("check_dan_mailbox", subject)


def check_ghi_mailbox(subject, session_id=None):
    _chk("check_ghi_mailbox", subject)


def check_docs_only_subject(subject, session_id=None):
    _chk("check_docs_only_subject", subject)


def check_system_read_subject(subject, session_id=None):
    _chk("check_system_read_subject", subject)
