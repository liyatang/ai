"""SQLite adapter: SQL extracts event metadata, never returns message bodies."""
from __future__ import annotations
import contextlib
import hashlib
import os
import re
import sqlite3
import time

LOG_PATH = os.path.expanduser('~/.codex/logs_2.sqlite')
TARGET_WEBSOCKET = 'codex_api::endpoint::responses_websocket'
TARGET_CLIENT = 'codex_core::client'
TARGET_OUTPUT = 'codex_core::stream_events_utils'
TARGET_RETRY = 'codex_core::responses_retry'
MAX_ROWS = 20000


def read_events(path=LOG_PATH, now=None):
    now = time.time() if now is None else now
    result = dict(state='unavailable', observed_at=now, events=[], error='Codex 日志不可用')
    if not os.path.exists(path):
        return result
    try:
        with contextlib.closing(sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=.2)) as db:
            db.execute('PRAGMA query_only=ON')
            columns = {r[1] for r in db.execute('PRAGMA table_info(logs)')}
            if not {'id','ts','ts_nanos','target','level','feedback_log_body'} <= columns:
                return {**result, 'error':'日志结构不支持'}
            process = 'process_uuid' if 'process_uuid' in columns else "''"
            thread = 'thread_id' if 'thread_id' in columns else "''"
            deadline = time.monotonic() + .8
            db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
            rows = db.execute(f'''
                SELECT id,ts,ts_nanos,{process},{thread},
                  CASE WHEN target=? THEN 'retry' WHEN target=? THEN 'output' ELSE 'activity' END,
                  CASE WHEN instr(feedback_log_body,'run_sampling_request{{turn_id=')>0 THEN
                    substr(feedback_log_body,instr(feedback_log_body,'run_sampling_request{{turn_id=')+length('run_sampling_request{{turn_id='),36) END
                FROM logs WHERE ts BETWEEN ? AND ? AND (
                  (target=? AND instr(feedback_log_body,'stream disconnected')>0) OR
                  (target=? AND level='DEBUG' AND instr(feedback_log_body,'Output item item_type=')>0) OR
                  (target IN (?,?) AND instr(feedback_log_body,'run_sampling_request{{turn_id=')>0))
                ORDER BY ts DESC,ts_nanos DESC,id DESC LIMIT ?
            ''', (TARGET_RETRY,TARGET_OUTPUT,int(now-360),int(now)+1,TARGET_RETRY,TARGET_OUTPUT,
                  TARGET_WEBSOCKET,TARGET_CLIENT,MAX_ROWS+1)).fetchall()
        events, unassociated = [], 0
        for ident,seconds,nanos,process,thread,kind,turn in rows[:MAX_ROWS]:
            at = seconds + nanos/1e9
            valid = bool(re.fullmatch(r'[0-9a-f-]{36}',turn or ''))
            # Never associate output/recovery without a turn boundary.
            task = hashlib.sha256(f'{process}:{thread}:{turn}'.encode()).hexdigest()[:24] if valid else None
            if not valid:
                unassociated += 1
            event_id = hashlib.sha256(f'{process}:{ident}:{seconds}:{nanos}'.encode()).hexdigest()[:24]
            events.append(dict(id=event_id,at=at,kind=kind,task=task))
        state = 'incomplete' if len(rows)>MAX_ROWS or unassociated else 'ok'
        return dict(state=state, observed_at=now,events=events,
                    error='日志采集不完整，无法可靠关联任务' if state!='ok' else None)
    except (sqlite3.Error,OSError,ValueError,TypeError):
        return result
