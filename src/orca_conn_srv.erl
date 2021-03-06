-module (orca_conn_srv).
-compile ({parse_transform, gin}).
-behaviour (gen_server).

-export ([ start_link/1 ]).
-export ([ set_active/2 ]).
-export ([ send_packet/3, recv_packet/1 ]).
-export ([ shutdown/2 ]).
-export ([
		init/1, enter_loop/1,
		handle_call/3,
		handle_cast/2,
		handle_info/2,
		terminate/2,
		code_change/3
	]).
-export ([
		tx_enter_loop/1
	]).
-include ("types.hrl").

-define( callback_log, {?MODULE, callback_log} ).
-define( callback_log_tcp, {?MODULE, callback_log_tcp} ).

-define( set_active( Mode ), {set_active, Mode} ).
-define( send_packet( SeqID, Packet ), {send_packet, SeqID, Packet} ).
-define( recv_packet(), recv_packet ).
-define( recv_default_timeout, 5000 ).
-define( shutdown( Reason ), {shutdown, Reason} ).

-define( hib_timeout, 5000 ).

-spec start_link( [ conn_opt() ] ) -> {ok, pid()}.
-spec set_active( pid(), once | true | false ) -> ok.
-spec send_packet( pid(), non_neg_integer(), binary() ) -> ok.
-spec recv_packet( pid() ) -> {ok, binary()} | {error, term()}.
-spec shutdown( pid(), term() ) -> ok.

start_link( Opts0 ) when is_list( Opts0 ) ->
	Opts1 = opts_ensure_controlling_process( Opts0 ),
	proc_lib:start_link( ?MODULE, enter_loop, [ Opts1 ] ).


tx_enter_loop( Tcp ) ->
	ok = proc_lib:init_ack( {ok, self()} ),
	tx_loop( Tcp ).

tx_loop( Tcp ) ->
	receive
		{send, DataToSend} ->
			ok = orca_tcp:send( Tcp, DataToSend ),
			tx_loop( Tcp );
		_Rubbish ->
			tx_loop( Tcp )
	end.

set_active( Srv, Mode )
	when (is_pid( Srv ) orelse is_atom( Srv ))
	andalso in( Mode, [ true, false, once ] )
->
	ok = gen_server:cast( Srv, ?set_active( Mode ) ).

send_packet( Srv, SeqID, Packet )
	when is_pid( Srv )
	andalso is_integer( SeqID ) andalso SeqID >= 0 andalso SeqID =< 255
	andalso is_binary( Packet )
->
	gen_server:cast( Srv, ?send_packet( SeqID, Packet ) ).

recv_packet( Srv ) when is_pid( Srv ) ->
	gen_server:call( Srv, ?recv_packet(), ?recv_default_timeout ).

shutdown( Srv, Reason ) when is_pid( Srv ) ->
	gen_server:call( Srv, ?shutdown( Reason ) ).


-record(s, {
		opts :: [ conn_opt() ],

		tcp :: orca_tcp:conn(),
		msg_port :: term(),
		msg_data :: atom(),
		msg_closed :: atom(),
		msg_error :: atom(),

		controlling_process :: pid(),
		controlling_process_mon_ref :: reference(),
		response_ctx :: orca_response:ctx(),

		active = false :: false | true | once,

		tx_pid :: pid(),

		sync_recv_reply_q = queue:new() :: queue:queue( {pid(), reference()} )
	}).

enter_loop( Opts ) ->
	{controlling_process, ControllingProcess} = lists:keyfind( controlling_process, 1, Opts ),

	ok = init_logging( Opts ),

	case init_tcp( Opts ) of
		{ok, Tcp} ->
			ok = proc_lib:init_ack( {ok, self()} ),

			ControllingProcessMonRef = erlang:monitor( process, ControllingProcess ),
			InitialActiveMode = proplists:get_value( active, Opts, false ),
			{ok, TxPid} = proc_lib:start_link( ?MODULE, tx_enter_loop, [ Tcp ] ),
			S0 = #s{
					opts = Opts,

					tcp = Tcp,
					tx_pid = TxPid,

					controlling_process = ControllingProcess,
					controlling_process_mon_ref = ControllingProcessMonRef,

					active = InitialActiveMode
				},
			enter_loop_init_tcp_ready( S0 );
		ErrorReply = {error, _} ->
			ok = proc_lib:init_ack( ErrorReply )
			% exit(shutdown)
	end.

init_tcp( Opts ) ->
	case {
		proplists:get_value( host, Opts ),
		proplists:get_value( port, Opts ),
		proplists:get_value( socket, Opts ),
		proplists:get_value( active, Opts, false )
	} of
		{Host, Port, undefined, _} when Host /= undefined andalso Port /= undefined ->
			orca_tcp:open( Host, Port );
		{undefined, undefined, Socket, false} when is_port( Socket ) ->
			orca_tcp:from_socket( Socket );
		{undefined, undefined, Socket, _} when is_port( Socket ) ->
			{error, pre_openned_socket_must_not_be_active};
		{_, _, _, _} ->
			{error, {either_optset_should_be_provided, {[host, port], [socket]} }}
	end.

init_logging( Opts ) ->
	LogF = proplists:get_value( callback_log, Opts, fun orca_default_callbacks:log_error_logger/2 ),
	undefined = erlang:put( ?callback_log, LogF ),
	TcpLogF = proplists:get_value( callback_log_tcp, Opts, fun orca_default_callbacks:log_tcp_null/3 ),
	undefined = erlang:put( ?callback_log_tcp, TcpLogF ),
	ok.

-spec enter_loop_init_tcp_ready( S0 :: #s{} ) -> no_return().
enter_loop_init_tcp_ready( S0 = #s{ tcp = Tcp, active = InitialActiveMode } ) ->
	{MsgData, MsgClosed, MsgError, MsgPort} = orca_tcp:messages( Tcp ),
	ok =
		case InitialActiveMode of
			false -> ok;
			_ -> orca_tcp:activate( Tcp )
		end,
	S1 = S0 #s{
			msg_data = MsgData,
			msg_closed = MsgClosed,
			msg_error = MsgError,
			msg_port = MsgPort,

			response_ctx = orca_response:new()
		},
	gen_server:enter_loop( ?MODULE, [], S1, ?hib_timeout ).



init( _ ) -> {stop, {error, enter_loop_used}}.

handle_call( ?shutdown( Reason ), GenReplyTo, State ) ->
	handle_call_shutdown( Reason, GenReplyTo, State );

handle_call( ?recv_packet(), GenReplyTo, State = #s{} ) ->
	handle_call_recv_packet( GenReplyTo, State );

handle_call(Request, From, State = #s{}) ->
	ok = log_report(warning, [
			?MODULE, handle_call,
			{bad_call, Request},
			{from, From}
		]),
	{reply, {badarg, Request}, State, ?hib_timeout}.

handle_cast( ?set_active( Mode ), State = #s{} ) ->
	handle_cast_set_active( Mode, State );

handle_cast( ?send_packet( SeqID, Packet ), State ) ->
	handle_cast_send_packet( SeqID, Packet, State );

handle_cast(Request, State = #s{}) ->
	ok = log_report(warning, [
				?MODULE, handle_cast,
				{bad_cast, Request}
			]),
	{noreply, State, ?hib_timeout}.

handle_info( timeout, State ) ->
	handle_info_timeout( State );

handle_info(
		{'DOWN', ControllingProcessMonRef, process, ControllingProcess, Reason},
		State = #s{
			controlling_process = ControllingProcess,
			controlling_process_mon_ref = ControllingProcessMonRef
		}
	) ->
		{stop, {shutdown, {controlling_process_terminated, Reason}}, State};

handle_info( {MsgClosed, MsgPort}, State = #s{ msg_closed = MsgClosed, msg_port = MsgPort } ) ->
	handle_info_closed( State );

handle_info( {MsgData, MsgPort, Data}, State = #s{ msg_data = MsgData, msg_port = MsgPort } ) ->
	ok = log_tcp( self(), in, Data ),
	handle_info_data( Data, State );

handle_info( Message, State = #s{} ) ->
	ok = log_report(warning, [
				?MODULE, handle_info,
				{bad_info, Message}
			]),
	{noreply, State, ?hib_timeout}.

terminate(_Reason, _State) ->
	ignore.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%% %%%%%%%% %%%
%%% Internal %%%
%%% %%%%%%%% %%%

opts_ensure_controlling_process( Opts0 ) ->
	_Opts1 =
		case lists:keyfind( controlling_process, 1, Opts0 ) of
			false -> [ {controlling_process, self()} | Opts0 ];
			{controlling_process, _} -> Opts0
		end.

handle_call_shutdown( Reason, _GenReplyTo, State ) ->
	{stop, Reason, ok, State}.

handle_cast_set_active( Mode, State0 = #s{} ) ->
	State1 = State0 #s{ active = Mode },
	{ok, State2} = maybe_deliver_packets( State1 ),
	{noreply, State2, ?hib_timeout}.

handle_info_data( Data, State0 = #s{ response_ctx = ResponseCtx0 } ) ->
	{ok, ResponseCtx1} = orca_response:data_in( Data, ResponseCtx0 ),
	State1 = State0 #s{ response_ctx = ResponseCtx1 },
	{ok, State2} = maybe_deliver_packets( State1 ),
	{noreply, State2, ?hib_timeout}.


handle_info_closed( State0 ) ->
	%% FIXME: deliver all the pending events prior to terminating.
	%% NOTE: the latter must be done regarding the "activeness" of this srv.
	{stop, {shutdown, tcp_closed}, State0}.
	% {noreply, State0}.

handle_cast_send_packet( SeqID, Packet, State = #s{ tx_pid = TxPid } ) ->
	PacketLen = size(Packet),
	PacketHeader = << PacketLen:24/little, SeqID:8/integer >>,
	DataToSend = iolist_to_binary([PacketHeader, Packet]),
	ok = log_tcp( self(), out, DataToSend ),
	% ok = orca_tcp:send( Tcp, DataToSend ),
	_ = erlang:send( TxPid, {send, DataToSend} ),
	{noreply, State, ?hib_timeout}.

handle_info_timeout( State ) ->
	{noreply, State, hibernate}.

handle_call_recv_packet( GenReplyTo, State = #s{ tcp = Tcp, response_ctx = ResponseCtx0, sync_recv_reply_q = Q0 } ) ->
	case orca_response:get_packet( ResponseCtx0 ) of
		{error, not_ready} ->
			ok = orca_tcp:activate( Tcp ),
			{noreply, State #s{ sync_recv_reply_q = queue:in( GenReplyTo, Q0 ) }};
		{ok, Packet, ResponseCtx1} ->
			ok = orca_tcp:activate( Tcp ),
			{reply, {ok, Packet}, State #s{ response_ctx = ResponseCtx1 } }
	end.

maybe_deliver_packets_to_sync_recipients( State0 = #s{ response_ctx = ResponseCtx0, sync_recv_reply_q = Q0 } ) ->
	case queue:peek( Q0 ) of
		empty -> {ok, State0};
		{value, SyncRecipient} ->
			case orca_response:get_packet( ResponseCtx0 ) of
				{error, not_ready} -> {ok, State0};
				{ok, Packet, ResponseCtx1} ->
					_ = gen_server:reply( SyncRecipient, {ok, Packet} ),
					Q1 = queue:drop( Q0 ),
					State1 = State0 #s{ response_ctx = ResponseCtx1, sync_recv_reply_q = Q1 },
					maybe_deliver_packets_to_sync_recipients( State1 )
			end
	end.

maybe_deliver_packets( State0 = #s{ active = false } ) ->
	{ok, _State1} = maybe_deliver_packets_to_sync_recipients( State0 );
maybe_deliver_packets(
	State0 = #s{
		active = ShouldSend
	}
) when in( ShouldSend, [ true, once ] ) ->
	{ok, State1 = #s{
			response_ctx = ResponseCtx0,
			controlling_process = ControllingProcess
		}} = maybe_deliver_packets_to_sync_recipients( State0 ),
	case orca_response:get_packet( ResponseCtx0 ) of
		{error, not_ready} ->
			maybe_activate_tcp( State1 );
		{ok, Packet, ResponseCtx1} ->
			ok = deliver_packet( ControllingProcess, Packet ),
			NextActiveMode =
				case ShouldSend of
					true -> true;
					once -> false
				end,
			State2 = State1 #s{ active = NextActiveMode, response_ctx = ResponseCtx1 },
			maybe_deliver_packets( State2 )
	end.

maybe_activate_tcp( State0 = #s{ active = false } ) -> {ok, State0};
maybe_activate_tcp( State0 = #s{ active = ShouldActivate, tcp = Tcp } )
	when in( ShouldActivate, [ true, once ] ) ->
		ok = orca_tcp:activate( Tcp ),
		{ok, State0}.

deliver_packet( ControllingProcess, Packet ) when is_pid( ControllingProcess ) andalso is_binary( Packet ) ->
	_ = erlang:send( ControllingProcess, {orca_packet, self(), Packet} ),
	ok.

log_report( Lvl, Report ) when in( Lvl, [info, warning, error] ) ->
	ok = (erlang:get(?callback_log)) ( Lvl, Report ).

log_tcp( Conn, Direction, Data ) ->
	ok = (erlang:get(?callback_log_tcp)) ( Conn, Direction, Data ).

