# Copyright (c) 2026 Beijing Volcano Engine Technology Co., Ltd.
# SPDX-License-Identifier: AGPL-3.0
"""Deterministic replacement of registered secrets with owner-bound references."""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Callable

from openviking.privacy.reference import build_privacy_field_reference
from openviking.pyagfs import get_privacy_matcher_class
from openviking.server.identity import RequestContext
from openviking_cli.exceptions import InvalidArgumentError, ResourceExhaustedError

if TYPE_CHECKING:
    from openviking.privacy.service import UserPrivacyConfigService

_AMBIGUOUS_PLACEHOLDER = "{{ov_privacy:ambiguous}}"
MIN_PROTECTED_VALUE_CHARS = 6
DEFAULT_MATCHER_CACHE_TTL_SECONDS = 3600.0
_MAX_SESSION_MATCHERS_PER_OWNER = 16
DEFAULT_SANITIZER_MAX_CONTENT_BYTES = 16 * 1024 * 1024
DEFAULT_SANITIZER_MAX_REPLACEMENTS = 10000


@dataclass(frozen=True)
class PrivacyReplacement:
    start: int
    end: int
    reference: str


@dataclass(frozen=True)
class PrivacySanitizationResult:
    content: str
    replacements: tuple[PrivacyReplacement, ...] = ()
    ambiguous_references: tuple[tuple[str, ...], ...] = ()
    match_limit_exceeded: bool = False

    @property
    def changed(self) -> bool:
        return bool(self.replacements)


class PrivacySanitizer:
    """Sanitize text with the active sensitive values owned by the current user."""

    def __init__(
        self,
        privacy: "UserPrivacyConfigService",
        *,
        cache_ttl_seconds: float = DEFAULT_MATCHER_CACHE_TTL_SECONDS,
        max_content_bytes: int = DEFAULT_SANITIZER_MAX_CONTENT_BYTES,
        max_replacements: int = DEFAULT_SANITIZER_MAX_REPLACEMENTS,
        monotonic_clock: Callable[[], float] = time.monotonic,
    ):
        if cache_ttl_seconds <= 0:
            raise ValueError("cache_ttl_seconds must be positive")
        if max_content_bytes <= 0:
            raise ValueError("max_content_bytes must be positive")
        if max_replacements <= 0:
            raise ValueError("max_replacements must be positive")
        self._privacy = privacy
        self._cache_ttl_seconds = float(cache_ttl_seconds)
        self._max_content_bytes = int(max_content_bytes)
        self._max_replacements = int(max_replacements)
        self._monotonic_clock = monotonic_clock
        matcher_class: Any = get_privacy_matcher_class()
        self._matcher_class = matcher_class
        self._cache: dict[tuple[str, str, int, bool, str | None], tuple[float, Any]] = {}
        self._cache_lock = asyncio.Lock()

    @property
    def max_content_bytes(self) -> int:
        """Maximum UTF-8 input size accepted by this sanitizer."""
        return self._max_content_bytes

    @property
    def max_replacements(self) -> int:
        return self._max_replacements

    async def prepare_matcher(
        self,
        ctx: RequestContext,
        *,
        prefer_credentials: bool = False,
        session_target_key: str | None = None,
    ) -> Callable[[str], list[PrivacyReplacement]]:
        """Prepare a bounded match query, optionally including one Session record.

        The callable may run in a worker thread. It returns positions and existing
        references so rule extraction can combine hits before rewriting content.
        """
        matcher = await self._matcher(
            ctx, prefer_credentials=prefer_credentials, session_target_key=session_target_key
        )

        def find(content: str) -> list[PrivacyReplacement]:
            try:
                replacements, ambiguous, exceeded = matcher.find_limited(
                    content, self._max_replacements, self._max_content_bytes
                )
            except OverflowError:
                raise ResourceExhaustedError(
                    "Content exceeds the Privacy sanitizer size limit"
                ) from None
            if ambiguous:
                raise InvalidArgumentError(
                    "Content contains a Privacy value mapped to multiple fields; "
                    "insert the intended owner-bound reference explicitly"
                )
            if exceeded:
                raise ResourceExhaustedError(
                    "Content exceeds the Privacy sanitizer replacement limit"
                )
            return [PrivacyReplacement(*item) for item in replacements]

        return find

    async def sanitize(
        self,
        content: str,
        *,
        ctx: RequestContext,
        uri: str = "",
        max_replacements: int | None = None,
        fail_on_match_limit: bool = True,
        prefer_credentials: bool = False,
    ) -> PrivacySanitizationResult:
        if not content or self._is_privacy_storage_uri(uri, ctx):
            return PrivacySanitizationResult(content=content)
        content_bytes = len(content.encode("utf-8"))
        if content_bytes > self._max_content_bytes:
            raise ResourceExhaustedError(
                "Content exceeds the Privacy sanitizer size limit",
                details={
                    "uri": uri,
                    "size_bytes": content_bytes,
                    "max_bytes": self._max_content_bytes,
                },
            )
        matcher = await self._matcher(ctx, prefer_credentials=prefer_credentials)
        effective_max_replacements = (
            self._max_replacements if max_replacements is None else max_replacements
        )
        if effective_max_replacements <= 0:
            raise ValueError("max_replacements must be positive")
        (
            rewritten,
            raw_replacements,
            raw_ambiguous,
            match_limit_exceeded,
        ) = matcher.sanitize_limited(content, effective_max_replacements)
        if match_limit_exceeded and fail_on_match_limit:
            raise ResourceExhaustedError(
                "Content exceeds the Privacy sanitizer replacement limit",
                details={
                    "uri": uri,
                    "max_replacements": effective_max_replacements,
                },
            )
        replacements = tuple(
            PrivacyReplacement(start=start, end=end, reference=reference)
            for start, end, reference in raw_replacements
        )
        return PrivacySanitizationResult(
            content=rewritten,
            replacements=replacements,
            ambiguous_references=tuple(tuple(items) for items in raw_ambiguous),
            match_limit_exceeded=match_limit_exceeded,
        )

    async def _matcher(
        self,
        ctx: RequestContext,
        *,
        prefer_credentials: bool = False,
        session_target_key: str | None = None,
    ) -> Any:
        revision = self._privacy.catalog_revision(ctx)
        cache_key = (ctx.account_id, ctx.user.user_id, revision, prefer_credentials, session_target_key)
        now = self._monotonic_clock()
        cached = self._cache.get(cache_key)
        if cached is not None and now - cached[0] < self._cache_ttl_seconds:
            return cached[1]
        async with self._cache_lock:
            now = self._monotonic_clock()
            self._cache = {
                key: item
                for key, item in self._cache.items()
                if now - item[0] < self._cache_ttl_seconds
            }
            cached = self._cache.get(cache_key)
            if cached is not None and now - cached[0] < self._cache_ttl_seconds:
                return cached[1]
            matcher = await self._build_matcher(
                ctx, prefer_credentials=prefer_credentials, session_target_key=session_target_key
            )
            owner_key = cache_key[:2]
            self._cache = {
                key: item
                for key, item in self._cache.items()
                if key[:2] != owner_key or key[2] == revision
            }
            self._cache[cache_key] = (now, matcher)
            if session_target_key is not None:
                # Insertion order evicts the oldest builds without counting user-wide matchers.
                session_keys = [
                    key for key in self._cache if key[:2] == owner_key and key[4] is not None
                ]
                for key in session_keys[:-_MAX_SESSION_MATCHERS_PER_OWNER]:
                    del self._cache[key]
            return matcher

    async def _build_matcher(
        self,
        ctx: RequestContext,
        *,
        prefer_credentials: bool,
        session_target_key: str | None,
    ) -> Any:
        references: dict[str, list[str]] = {}
        credentials: dict[str, list[str]] = {}
        for category in await self._privacy.list_categories(ctx):
            if category == "session":
                if session_target_key is None:
                    continue
                target_keys = [session_target_key]
            else:
                target_keys = await self._privacy.list_targets(ctx, category)
            for target_key in target_keys:
                current = await self._privacy.get_current(ctx, category, target_key)
                if current is None:
                    continue
                for field_name, value in current.values.items():
                    # Privacy is the explicit protection boundary. Do not infer
                    # sensitivity from field names. Very short values are not
                    # safe for global substring replacement because ordinary
                    # prose would produce excessive false positives.
                    if (
                        not isinstance(value, str)
                        or len(value) < MIN_PROTECTED_VALUE_CHARS
                    ):
                        continue
                    reference = build_privacy_field_reference(
                        ctx.user.user_id,
                        category,
                        target_key,
                        field_name,
                    )
                    references.setdefault(value, []).append(reference)
                    if prefer_credentials and category == "credential":
                        credentials.setdefault(value, []).append(reference)

        targets: dict[str, list[str]] = {}
        for secret, candidates in references.items():
            targets[secret] = sorted(set(credentials.get(secret, candidates)))
        return self._matcher_class(targets, _AMBIGUOUS_PLACEHOLDER)

    @staticmethod
    def _is_privacy_storage_uri(uri: str, ctx: RequestContext) -> bool:
        root = f"viking://user/{ctx.user.user_id}/privacy"
        return uri.rstrip("/") == root or uri.startswith(f"{root}/")
