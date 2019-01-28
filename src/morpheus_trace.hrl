-define(TraceCall(TS, From, Where, Req), {TS, call, {From, Where, Req}}).
-define(TraceNewProcess(TS, Proc, AbsId, Creator, EntryInfo), {TS, new_process, {Proc, AbsId, Creator, EntryInfo}}).
-define(TraceSend(TS, Where, From, To, Type, Content, Effect), {TS, send, {Where, From, To, Type, Content, Effect}}).
-define(TraceRecv(TS, Where, To, Type, Content), {TS, recv, {Where, To, Type, Content}}).
-define(TraceReportState(TS, TraceInfo, State), {TS, report_state, TraceInfo, State}).
