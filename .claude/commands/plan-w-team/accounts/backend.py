#!/usr/bin/env python3
"""Coordination backend seam for multi-account management.

Phase 1 ships the LOCAL default only; the remote (cross-machine) backend is a
DELIBERATE, documented stub (operator BRIEF: build the seam + local default now,
not the mac-mini/Helm host backend). The interface is what lets a Phase-2
``RemoteBackend`` drop in without touching any caller:

  * registry access goes through ``load_registry`` / ``save_registry`` so a
    networked store can substitute for the local file;
  * lane leases (``acquire_lane_lease`` / ``release_lane_lease``) carry an
    ``owner_id`` and a TTL so a shared lease store can arbitrate which machine
    owns a lane — locally they are no-ops (a single machine never contends).

``save_registry`` is compare-and-set: it refuses to overwrite a registry that
changed under it (``VersionConflict``), the lost-update guard a shared store
needs. Locally this is belt-and-braces on top of ``registry.py``'s flock.
"""
from __future__ import annotations

import abc

import registry


class VersionConflict(Exception):
    """save_registry was given a stale ``expected_version`` — the on-disk registry
    changed since the caller read it. The caller must re-read and retry."""


class CoordinationBackend(abc.ABC):
    """The pluggable coordination interface (registry access + lane leases)."""

    @abc.abstractmethod
    def load_registry(self) -> dict:
        """Return the current registry object."""

    @abc.abstractmethod
    def save_registry(self, data: dict, expected_version: int) -> dict:
        """Persist *data* iff the stored registry still has ``expected_version``
        (compare-and-set). Raise ``VersionConflict`` otherwise."""

    @abc.abstractmethod
    def acquire_lane_lease(self, lane_id: str, owner_id: str, ttl: int) -> bool:
        """Try to take a lease on *lane_id* for *owner_id*, valid for *ttl*
        seconds. Return True on success, False if another owner holds it."""

    @abc.abstractmethod
    def release_lane_lease(self, lane_id: str, owner_id: str) -> None:
        """Release *lane_id* iff *owner_id* holds it (no-op otherwise)."""


class LocalBackend(CoordinationBackend):
    """The wired default: single machine, registry via ``registry.py``.

    Leases are no-ops that always succeed — one machine never contends for its
    own lanes, so a lease is trivially available. The CAS check on
    ``save_registry`` is the one real guard (against two local processes racing a
    registry write); it complements the flock that ``registry.save`` already
    holds."""

    def __init__(self, path: str = None):
        self._path = path

    def load_registry(self) -> dict:
        return registry.load(self._path)

    def save_registry(self, data: dict, expected_version: int) -> dict:
        # CAS: the on-disk version must still match what the caller read.
        current = registry.load(self._path)
        if current.get("version") != expected_version:
            raise VersionConflict(
                "registry version is %r, expected %r — re-read and retry"
                % (current.get("version"), expected_version))
        return registry.save(data, self._path)

    def acquire_lane_lease(self, lane_id: str, owner_id: str, ttl: int) -> bool:
        return True  # single machine: always available

    def release_lane_lease(self, lane_id: str, owner_id: str) -> None:
        return None  # single machine: nothing to release


class RemoteBackend(CoordinationBackend):
    """Phase-2 cross-machine backend — NOT IMPLEMENTED (operator BRIEF stub).

    The extension contract for whoever builds it:

      * ``load_registry`` / ``save_registry`` target a SHARED store (a synced
        file, an object store, or a small networked service) rather than the
        local 0600 file. ``save_registry`` keeps the compare-and-set semantics on
        a monotonically-increasing ``version`` so two machines cannot lose each
        other's ``add-account`` / ``deactivate`` writes.
      * ``acquire_lane_lease`` records ``(lane_id -> {owner_id, expires_at})`` in
        the shared store with atomic acquire (e.g. a conditional put); a lease is
        grantable only if unheld or expired past its TTL. ``release_lane_lease``
        clears it iff ``owner_id`` matches. This is what lets several machines
        draw on the same per-account-global 5h/7d pool without double-spending a
        lane.
      * Tokens still NEVER leave a machine except as the ``Authorization: Bearer``
        header to ``api.anthropic.com`` — a remote store coordinates LEASES and
        registry METADATA, not token material in transit unless it is itself a
        0600-equivalent secret store the operator has vetted.
    """

    _MSG = ("RemoteBackend is a Phase-2 stub (operator BRIEF: local default only "
            "this run). Implement against the CoordinationBackend contract — see "
            "the class docstring.")

    def __init__(self, *args, **kwargs):
        # Constructing is allowed (so callers can reference the type / register it);
        # every operation raises until Phase 2 implements it.
        self._args = args
        self._kwargs = kwargs

    def load_registry(self) -> dict:
        raise NotImplementedError(self._MSG)

    def save_registry(self, data: dict, expected_version: int) -> dict:
        raise NotImplementedError(self._MSG)

    def acquire_lane_lease(self, lane_id: str, owner_id: str, ttl: int) -> bool:
        raise NotImplementedError(self._MSG)

    def release_lane_lease(self, lane_id: str, owner_id: str) -> None:
        raise NotImplementedError(self._MSG)
