#!/usr/bin/env python3

import configparser
import json
import os
from pathlib import Path
import pwd
import re
import stat
import sys
import tempfile


MAX_FILE_BYTES = 4096
USERNAME = re.compile(r"[a-z_][a-z0-9_-]*\$?", re.ASCII)


class OwnerError(ValueError):
    pass


def validate_identity(user, uid):
    if not isinstance(user, str) or len(user) > 32 or USERNAME.fullmatch(user) is None:
        raise OwnerError("The owner username is invalid")
    if user in {"root", "nobody"} or type(uid) is not int or not 1000 <= uid < 4_294_967_295 or uid == 65534:
        raise OwnerError("The owner must be a regular non-root account")
    return {"user": user, "uid": uid}


def require_trusted_directory(path, root, root_uid):
    try:
        path.relative_to(root)
    except ValueError as error:
        raise OwnerError("The owner path is outside the system root") from error
    while True:
        attributes = path.lstat()
        if not stat.S_ISDIR(attributes.st_mode) or attributes.st_uid != root_uid or attributes.st_mode & 0o022:
            raise OwnerError("The owner path must use root-owned, non-writable directories")
        if path == root:
            return
        path = path.parent


def read_trusted_file(path, root, root_uid):
    require_trusted_directory(path.parent, root, root_uid)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        attributes = os.fstat(descriptor)
        if not stat.S_ISREG(attributes.st_mode) or attributes.st_uid != root_uid or attributes.st_mode & 0o022:
            raise OwnerError("The owner source must be a root-owned, non-writable regular file")
        if attributes.st_size > MAX_FILE_BYTES:
            raise OwnerError("The owner file is too large")
        contents = os.read(descriptor, MAX_FILE_BYTES + 1)
        if len(contents) > MAX_FILE_BYTES:
            raise OwnerError("The owner file is too large")
        return contents.decode("utf-8")
    finally:
        os.close(descriptor)


def owner_from_autologin(contents, passwd_lookup):
    config = configparser.ConfigParser(interpolation=None, strict=True, empty_lines_in_values=False)
    try:
        config.read_string(contents)
    except configparser.Error as error:
        raise OwnerError("The first-owner login configuration is invalid") from error
    if config.defaults() or config.sections() != ["Autologin"]:
        raise OwnerError("The first-owner login configuration is ambiguous")
    section = config["Autologin"]
    if set(section) != {"user", "session"} or section["session"] != "omarchy.desktop":
        raise OwnerError("The first-owner login configuration is incomplete")
    user = section["user"]
    validate_identity(user, 1000)
    try:
        account = passwd_lookup(user)
    except KeyError as error:
        raise OwnerError("The first-owner account does not exist") from error
    if account.pw_name != user or not account.pw_shell.startswith("/") or Path(account.pw_shell).name in {"false", "nologin"}:
        raise OwnerError("The first-owner account cannot log in")
    return validate_identity(account.pw_name, account.pw_uid)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise OwnerError("The saved owner has duplicate fields")
        result[key] = value
    return result


def read_saved_owner(path, root, root_uid):
    try:
        owner = json.loads(read_trusted_file(path, root, root_uid), object_pairs_hook=unique_object)
    except (json.JSONDecodeError, RecursionError) as error:
        raise OwnerError("The saved owner is invalid") from error
    if not isinstance(owner, dict) or set(owner) != {"user", "uid"}:
        raise OwnerError("The saved owner has invalid fields")
    return validate_identity(owner["user"], owner["uid"])


def require_finished_provisioning(root):
    directory = root / "var/lib/omarchy/provisioning"
    if any(os.path.lexists(directory / name) for name in ("pending", "wipe-pending")):
        raise OwnerError("First-owner provisioning has not completed")


def record_owner(root=Path("/"), root_uid=0, passwd_lookup=pwd.getpwnam):
    require_finished_provisioning(root)
    autologin = root / "etc/sddm.conf.d/autologin.conf"
    owner = owner_from_autologin(read_trusted_file(autologin, root, root_uid), passwd_lookup)
    state_directory = root / "var/lib/omabox"
    require_trusted_directory(state_directory.parent, root, root_uid)
    state_directory.mkdir(mode=0o755, exist_ok=True)
    require_trusted_directory(state_directory, root, root_uid)
    state_directory.chmod(0o755)
    marker = state_directory / "owner.json"
    require_finished_provisioning(root)
    if os.path.lexists(marker):
        if read_saved_owner(marker, root, root_uid) != owner:
            raise OwnerError("A different first owner is already recorded")
        return False
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".owner-", dir=state_directory, delete=False) as output:
            temporary = Path(output.name)
            os.fchmod(output.fileno(), 0o644)
            output.write((json.dumps(owner, separators=(",", ":")) + "\n").encode("utf-8"))
            output.flush()
            os.fsync(output.fileno())
        require_finished_provisioning(root)
        try:
            os.link(temporary, marker, follow_symlinks=False)
        except FileExistsError:
            if read_saved_owner(marker, root, root_uid) != owner:
                raise OwnerError("A different first owner is already recorded")
            return False
        descriptor = os.open(state_directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        return True
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    if sys.argv[1:] or os.geteuid() != 0:
        print("The owner recorder must run as root without arguments.", file=sys.stderr)
        return 1
    try:
        record_owner()
    except (OSError, OwnerError, UnicodeError):
        print("The first owner could not be recorded; SSH remains unavailable.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
