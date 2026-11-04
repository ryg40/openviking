# Copyright (c) 2026 Beijing Volcano Engine Technology Co., Ltd.
# SPDX-License-Identifier: AGPL-3.0

"""MCP remember results use owner-scoped terminal tasks without forcing retention."""

import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from mcp.types import CallToolRequest, CallToolRequestParams

import openviking.server.mcp_endpoint as mcp_endpoint
import openviking.service.task_tracker as task_tracker
from openviking.server.identity import RequestContext, Role
from openviking.service.task_store import PersistentTaskStore
from openviking.service.task_tracker import TaskStatus, TaskTracker
from openviking_cli.session.user_id import UserIdentifier
from tests.utils.mock_agfs import MockLocalAGFS

MESSAGES = [{"role": "user", "content": "I prefer Python for coding."}]
NO_CHANGES = "No memory changes were selected by extraction; nothing new was stored."


@pytest.fixture
async def remember_task(tmp_path, monkeypatch):
    ctx = RequestContext(UserIdentifier("sample-account", "sample-user"), Role.USER)
    owner = {"account_id": ctx.account_id, "user_id": ctx.user.user_id}
    tracker = TaskTracker(PersistentTaskStore(MockLocalAGFS(root_path=tmp_path)))
    session = SimpleNamespace(add_message_async=AsyncMock())
    service = SimpleNamespace(sessions=SimpleNamespace(open=AsyncMock(return_value=session)))

    async def commit(session_id, request_ctx):
        assert request_ctx is ctx
        task = await tracker.create("session_commit", resource_id=session_id, **owner)
        await tracker.start(task.task_id, **owner)
        return {"status": "accepted", "task_id": task.task_id}

    service.sessions.commit_async = AsyncMock(side_effect=commit)
    monkeypatch.setattr(mcp_endpoint, "get_service", lambda: service)
    monkeypatch.setattr(task_tracker, "get_task_tracker", lambda: tracker)
    token = mcp_endpoint._mcp_ctx.set(ctx)
    try:
        yield SimpleNamespace(tracker=tracker, service=service, owner=owner, session=session)
    finally:
        mcp_endpoint._mcp_ctx.reset(token)


async def _call_remember(**arguments):
    handler = mcp_endpoint.mcp._mcp_server.request_handlers[CallToolRequest]
    response = await handler(
        CallToolRequest(params=CallToolRequestParams(name="remember", arguments=arguments))
    )
    return response.root


def _text(result):
    return "\n".join(block.text for block in result.content)


async def _terminal_commit(harness, result=None, *, error=None, cancelled=False):
    commit = harness.service.sessions.commit_async.side_effect

    async def finish(session_id, ctx):
        response = await commit(session_id, ctx)
        task_id = response["task_id"]
        if error is not None:
            await harness.tracker.fail(task_id, error, **harness.owner)
        elif cancelled:
            await harness.tracker.cancel(task_id, **harness.owner)
        else:
            await harness.tracker.complete(task_id, result, **harness.owner)
        return response

    harness.service.sessions.commit_async.side_effect = finish


async def test_remember_schema_has_opt_in_bounded_wait():
    tools = {tool.name: tool for tool in await mcp_endpoint.mcp.list_tools()}
    schema = tools["remember"].inputSchema
    assert schema["required"] == ["messages"]
    assert schema["properties"]["wait"]["default"] is False
    assert schema["properties"]["timeout"]["default"] == 30.0
    assert schema["properties"]["timeout"]["minimum"] == 0
    assert schema["properties"]["timeout"]["maximum"] == 300
    assert "does not cancel extraction" in tools["remember"].description


@pytest.mark.parametrize("arguments", [{}, {"wait": False, "timeout": 0}])
async def test_remember_default_preserves_async_response(remember_task, monkeypatch, arguments):
    wait = AsyncMock(wraps=remember_task.tracker.wait)
    monkeypatch.setattr(remember_task.tracker, "wait", wait)
    result = await _call_remember(messages=MESSAGES, **arguments)
    session_id = remember_task.service.sessions.open.call_args.args[0]
    task = (await remember_task.tracker.list_tasks(**remember_task.owner))[0]
    assert result.isError is False
    assert _text(result) == (
        f"Submitted 1 message(s) for memory extraction (session {session_id}, "
        f"task_id={task.task_id}). Extraction runs in the background and decides which memories "
        "to create or update."
    )
    wait.assert_not_awaited()
    assert task.status == TaskStatus.RUNNING
    remember_task.session.add_message_async.assert_awaited_once()


async def test_remember_wait_positive_extraction(remember_task, monkeypatch):
    await _terminal_commit(remember_task, {"memories_extracted": {"preferences": 1, "entities": 2}})
    wait = AsyncMock(wraps=remember_task.tracker.wait)
    monkeypatch.setattr(remember_task.tracker, "wait", wait)
    result = await _call_remember(messages=MESSAGES, wait=True, timeout=5)
    task = (await remember_task.tracker.list_tasks(**remember_task.owner))[0]
    assert result.isError is False
    assert _text(result) == (
        f"Memory extraction completed (task_id={task.task_id}, status=completed, "
        "memories_extracted=3)."
    )
    wait.assert_awaited_once_with(task.task_id, **remember_task.owner, timeout=5)
    assert NO_CHANGES not in _text(result)


@pytest.mark.parametrize("counts", [{}, {"preferences": 0}])
async def test_remember_wait_valid_noop(remember_task, counts):
    await _terminal_commit(remember_task, {"memories_extracted": counts})
    result = await _call_remember(messages=MESSAGES, wait=True)
    assert result.isError is False
    assert "status=completed, memories_extracted=0" in _text(result)
    assert _text(result).endswith(NO_CHANGES)
    assert "rejected" not in _text(result)
    assert "duplicate" not in _text(result)


async def test_remember_wait_duplicate_noop_does_not_invent_reason(remember_task):
    commit = remember_task.service.sessions.commit_async.side_effect
    counts = iter([{"preferences": 1}, {}])

    async def extract(session_id, ctx):
        response = await commit(session_id, ctx)
        await remember_task.tracker.complete(
            response["task_id"], {"memories_extracted": next(counts)}, **remember_task.owner
        )
        return response

    remember_task.service.sessions.commit_async.side_effect = extract
    first = await _call_remember(messages=MESSAGES, wait=True)
    repeated = await _call_remember(messages=MESSAGES, wait=True)
    assert first.isError is False
    assert "memories_extracted=1" in _text(first)
    assert repeated.isError is False
    assert "memories_extracted=0" in _text(repeated)
    assert _text(repeated).endswith(NO_CHANGES)
    assert "duplicate" not in _text(repeated)
    assert len(await remember_task.tracker.list_tasks(**remember_task.owner)) == 2


@pytest.mark.parametrize("cancelled", [False, True])
async def test_remember_wait_terminal_failure_sets_mcp_error(remember_task, cancelled):
    await _terminal_commit(
        remember_task,
        error=None if cancelled else "Extraction failed",
        cancelled=cancelled,
    )
    result = await _call_remember(messages=MESSAGES, wait=True)
    task = (await remember_task.tracker.list_tasks(**remember_task.owner))[0]
    assert result.isError is True
    assert f"task_id={task.task_id}, status={task.status.value}" in _text(result)
    if not cancelled:
        assert "Extraction failed" in _text(result)
    assert NO_CHANGES not in _text(result)
    assert "memories_extracted=0" not in _text(result)


async def test_remember_wait_missing_count_is_not_reported_as_noop(remember_task):
    await _terminal_commit(remember_task, {})
    result = await _call_remember(messages=MESSAGES, wait=True)
    assert result.isError is True
    assert "completed without an extraction count" in _text(result)
    assert "task_id=" in _text(result)
    assert NO_CHANGES not in _text(result)


@pytest.mark.parametrize("timeout", [0, 0.01])
async def test_remember_wait_timeout_keeps_task_running(remember_task, timeout):
    result = await asyncio.wait_for(
        _call_remember(messages=MESSAGES, wait=True, timeout=timeout), timeout=2
    )
    task = (await remember_task.tracker.list_tasks(**remember_task.owner))[0]
    assert result.isError is False
    assert f"wait timed out (task_id={task.task_id})" in _text(result)
    assert "The task still runs in the background" in _text(result)
    assert task.status == TaskStatus.RUNNING
    assert NO_CHANGES not in _text(result)
    await remember_task.tracker.complete(
        task.task_id, {"memories_extracted": {"preferences": 1}}, **remember_task.owner
    )
    terminal = await remember_task.tracker.wait(task.task_id, **remember_task.owner, timeout=0)
    assert terminal.status == TaskStatus.COMPLETED
    assert terminal.result["memories_extracted"] == {"preferences": 1}


async def test_remember_wait_observes_background_completion(remember_task):
    original_wait = remember_task.tracker.wait
    entered = asyncio.Event()

    async def wait(*args, **kwargs):
        entered.set()
        return await original_wait(*args, **kwargs)

    remember_task.tracker.wait = wait
    call = asyncio.create_task(_call_remember(messages=MESSAGES, wait=True, timeout=2))
    try:
        await asyncio.wait_for(entered.wait(), timeout=1)
        task = (await remember_task.tracker.list_tasks(**remember_task.owner))[0]
        assert task.status == TaskStatus.RUNNING
        await remember_task.tracker.complete(
            task.task_id, {"memories_extracted": {"preferences": 1}}, **remember_task.owner
        )
        result = await asyncio.wait_for(call, timeout=1)
        assert result.isError is False
        assert "status=completed, memories_extracted=1" in _text(result)
    finally:
        call.cancel()
        await asyncio.gather(call, return_exceptions=True)


async def test_remember_wait_skipped_commit_does_not_wait(remember_task, monkeypatch):
    remember_task.service.sessions.commit_async.side_effect = None
    remember_task.service.sessions.commit_async.return_value = {
        "status": "skipped",
        "reason": "no_messages",
        "task_id": None,
    }
    wait = AsyncMock()
    monkeypatch.setattr(remember_task.tracker, "wait", wait)
    result = await _call_remember(messages=[], wait=True)
    assert result.isError is False
    assert _text(result) == "Nothing was committed for memory extraction (reason: no_messages)."
    wait.assert_not_awaited()


@pytest.mark.parametrize("timeout", [-1, 301, float("inf"), float("nan"), None])
async def test_remember_rejects_unbounded_wait_before_submission(remember_task, timeout):
    result = await _call_remember(messages=MESSAGES, wait=True, timeout=timeout)
    assert result.isError is True
    remember_task.service.sessions.open.assert_not_awaited()
    remember_task.service.sessions.commit_async.assert_not_awaited()
