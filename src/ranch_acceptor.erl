%% Copyright (c) 2011-2012, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

%% @private
-module(ranch_acceptor).

%% API.
-export([start_link/7]).

%% Internal.
-export([init/5]).
-export([async_init/4]).
-export([async_loop/4]).
-export([sync_loop/4]).

%% API.

-spec start_link(any(), inet:socket(), module(), module(), pid(), pid(), any())
	-> {ok, pid()}.
start_link(Ref, LSocket, Transport, Protocol, ListenerPid, ConnsSup, AccOpts) ->
	{ok, MaxConns} = ranch_listener:get_max_connections(ListenerPid),
	{ok, Opts} = ranch_listener:get_protocol_options(ListenerPid),
	SyncAccept = lists:member({sync_accept, true}, AccOpts),
	SyncHandle = lists:member({sync_handle, true}, AccOpts),
	Pid = spawn_link(?MODULE, init,
		[LSocket, Transport, {Protocol, MaxConns, Opts, ListenerPid, ConnsSup}, SyncAccept, SyncHandle]),
	ok = ranch_server:add_acceptor(Ref, Pid),
	{ok, Pid}.

%% Internal.

-spec init(inet:socket(), module(), tuple(), boolean(), boolean()) -> no_return().
init(LSocket, Transport, Opts, false, SyncHandle) ->
	async_init(LSocket, Transport, Opts, SyncHandle);

init(LSocket, Transport, Opts, true, SyncHandle) ->
	sync_loop(LSocket, Transport, Opts, SyncHandle).

-spec async_init(inet:socket(), module(), tuple(), boolean()) -> no_return().
async_init(LSocket, Transport, Opts, SyncHandle) ->
	async_accept(LSocket, Transport),
	async_loop(LSocket, Transport, Opts, SyncHandle).

-spec async_loop(inet:socket(), module(), tuple(), boolean()) -> no_return().
async_loop(LSocket, Transport, Opts = {Protocol, MaxConns, _, ListenerPid, ConnsSup}, SyncHandle) ->
	receive
		%% We couldn't accept the socket but it's safe to continue.
		{accept, continue} ->
			?MODULE:async_init(LSocket, Transport, Opts, SyncHandle);
		%% Found my sockets!
		{accept, CSocket} ->
			Opts2 = handle(Transport, CSocket, Opts, SyncHandle),
			?MODULE:async_init(LSocket, Transport, Opts2, SyncHandle);
		%% Upgrade the max number of connections allowed concurrently.
		{set_max_conns, MaxConns2} ->
			?MODULE:async_loop(LSocket, Transport, {Protocol,
				MaxConns2, Opts, ListenerPid, ConnsSup}, SyncHandle);
		%% Upgrade the protocol options.
		{set_opts, Opts2} ->
			?MODULE:async_loop(LSocket, Transport, {Protocol,
					MaxConns, Opts2, ListenerPid, ConnsSup}, SyncHandle)
	end.

-spec sync_loop(inet:socket(), module(), tuple(), boolean()) -> no_return().
sync_loop(LSocket, Transport, Opts = {Protocol, MaxConns, ProtoOpts, ListenerPid, ConnsSup}, SyncHandle) ->
	receive
		%% Upgrade the max number of connections allowed concurrently.
		{set_max_conns, MaxConns2} ->
			Opts2 = {Protocol, MaxConns2, ProtoOpts, ListenerPid, ConnsSup},
			?MODULE:sync_loop(LSocket, Transport, Opts2, SyncHandle);
		{set_opts, ProtoOpts2} ->
			Opts2 = {Protocol, MaxConns, ProtoOpts2, ListenerPid, ConnsSup},
			?MODULE:sync_loop(LSocket, Transport, Opts2, SyncHandle)
	after 0 ->
		ok
	end,
	case Transport:accept(LSocket, infinity) of
		{ok, CSocket} ->
			Opts3 = handle(Transport, CSocket, Opts, SyncHandle),
			?MODULE:sync_loop(LSocket, Transport, Opts3, SyncHandle);
		%% We want to crash if the listening socket got closed.
		{error, closed} ->
			exit(closed);
		{error, _Reason} ->
			?MODULE:sync_loop(LSocket, Transport, Opts, SyncHandle)
	end.

handle(Transport, CSocket, {Protocol, MaxConns, Opts, ListenerPid, ConnsSup}, false) ->
	{ok, ConnPid} = supervisor:start_child(ConnsSup,
		[ListenerPid, CSocket, Transport, Protocol, Opts]),
	Transport:controlling_process(CSocket, ConnPid),
	ConnPid ! {shoot, ListenerPid},
	NbConns = ranch_listener:add_connection(ListenerPid, ConnPid),
	{ok, MaxConns2} = maybe_wait(ListenerPid, MaxConns, NbConns),
	{Protocol, MaxConns2, Opts, ListenerPid, ConnsSup};

handle(Transport, CSocket, Opts = {Protocol, _, ProtoOpts, ListenerPid, _}, true) ->
	self() ! {shoot, ListenerPid},
	%% let it fall awhile
	Protocol:init(ListenerPid, CSocket, Transport, ProtoOpts),
	Opts.

-spec maybe_wait(pid(), MaxConns, non_neg_integer())
	-> {ok, MaxConns} when MaxConns::ranch:max_conns().
maybe_wait(_, MaxConns, NbConns) when MaxConns > NbConns ->
	{ok, MaxConns};
maybe_wait(ListenerPid, MaxConns, NbConns) ->
	receive
		{set_max_conns, MaxConns2} ->
			maybe_wait(ListenerPid, MaxConns2, NbConns)
	after 0 ->
		NbConns2 = ranch_server:count_connections(ListenerPid),
		maybe_wait(ListenerPid, MaxConns, NbConns2)
	end.

-spec async_accept(inet:socket(), module()) -> ok.
async_accept(LSocket, Transport) ->
	AcceptorPid = self(),
	_ = spawn_link(fun() ->
		case Transport:accept(LSocket, infinity) of
			{ok, CSocket} ->
				Transport:controlling_process(CSocket, AcceptorPid),
				AcceptorPid ! {accept, CSocket};
			%% We want to crash if the listening socket got closed.
			{error, Reason} when Reason =/= closed ->
				AcceptorPid ! {accept, continue}
		end
	end),
	ok.
