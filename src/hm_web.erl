-module(hm_web).

-export([start/1, stop/0, loop/2, do_stream/4]).

%% External API

start(Options) ->
    {DocRoot, Options1} = get_option(docroot, Options),
    Loop = fun (Req) ->
                   ?MODULE:loop(Req, DocRoot)
           end,
    mochiweb_http:start([{name, ?MODULE}, {loop, Loop} | Options1]).

stop() ->
    mochiweb_http:stop(?MODULE).

loop(Req, _) ->
    "/" ++ Path = Req:get(path),
    case Req:get(method) of
        Method when Method =:= 'GET'; Method =:= 'HEAD' ->
            case Path of
                "subscribe" ->
			QueryString = Req:parse_qs(),
			case lists:keysearch("callback", 1, QueryString) of
				false ->
					Type = normal;
				{value, {_, Z}} ->
					Type = {callback, Z}
			end,
			case full_keyfind("channel", 1, QueryString) of
				[] ->
					Channels = null;
				List ->
					Channels = [ C || {_, C} <- List ]
			end,
			case lists:keysearch("since", 1, QueryString) of
				false ->
					Since = null;
				{value, {_, Y}} ->
					%% TODO: Watch out for non-int
					{Since, _} = string:to_integer(Y)
			end,
			if
				Channels /= null ->
					?MODULE:do_stream(Req, Channels, Since, Type);
				true ->
					Req:respond({400, [], []})
			end;
		_ ->
			Req:not_found()
            end;
        'POST' ->
            case Path of
                _ ->
                    Req:not_found()
            end;
        _ ->
            Req:respond({501, [], []})
    end.

% Procedure of starting a a stream:
% This is long-polling. So first we need to make sure we haven't missed anything.
% This is done by using the provided Since parameter, if it exists:
%  Get all the channel logs for the requested channels, and if there are any messages
%  in the logs with an id of < Since, send the first one. We're not going to bundle them
%  together because we don't know how - we could be sending anything.
% If there wasn't anything, then time to subscribe to them all. The first one that sends a response
% gets sent.
do_stream(Req, Channels, Since, Type) ->
	case Since of
		null ->
			% Much easier
			[ hm_server:login(C, self()) || C <- Channels ],
			Response = Req:ok({"text/html; charset=utf-8",
				   [{"Server","Hydrometeor"}], chunked}),
			feed(Response, Type);
		_ ->
			% Get all the logs
			L = lists:flatten([ hm_server:get_channel_log(C, max) || C <- Channels ]),
			% Find all messages greater_than Since
			M = [ {Id, Msg} || {Id, Msg} <- L,
					   Id > Since],
			case M of
				[] ->
					% There isn't one, do_stream without Since
					do_stream(Req, Channels, null, Type);
				_ ->
					% Find the smallest
					{Id, Msg} = smallest_id(M),
					% Send ourselves the message, then call feed
					self() ! {router_msg, {Id, Msg}},
		                        Response = Req:ok({"text/html; charset=utf-8",
       				                   [{"Server","Hydrometeor"}], chunked}),
					feed(Response, Type)
			end
	end.

%% Internal API

get_option(Option, Options) ->
    {proplists:get_value(Option, Options), proplists:delete(Option, Options)}.

feed(Response, Type) ->
        receive
        {router_msg, {Id, Msg}} ->
		R = [integer_to_list(Id),",",binary_to_list(Msg)],
                case Type of
                        normal ->
                                Response:write_chunk(R);
                        {callback, Callback} ->
                                Response:write_chunk([Callback, "(", R, ")"])
                end
        end,
        Response:write_chunk([]).

full_keyfind(Key, N, List) ->
        case lists:keytake(Key, N, List) of
                false ->
                        [];
                {value, Tuple, List2} ->
                        [Tuple | full_keyfind(Key, N, List2)]
        end.

% This should never be called.
smallest_id([]) ->
	{0, error};
smallest_id(L) ->
	smallest_id_(L, 0, 0).

smallest_id_([], Acc, AccMsg) ->	
	{Acc, AccMsg};
smallest_id_([{Id, Msg} | T], Acc, AccMsg) ->
	if
		Id < Acc ->
			smallest_id_(T, Id, Msg);
		Acc == 0 ->
			smallest_id_(T, Id, Msg);
		true ->
			smallest_id_(T, Acc, AccMsg)
	end.