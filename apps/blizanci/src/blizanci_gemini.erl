%% blizanci, a Gemini protocol server, by Martin Keegan
%%
%% To the extent (if any) permissible by law, Copyright (C) 2020  Martin Keegan
%%
%% This programme is free software; you may redistribute and/or modify it under
%% the terms of the Apache Software Licence v2.0.

% The main code path consists in transforming data and handing it off
% down the call chain (always towards the bottom of the file) as follows:
%
%   handle_info({ssl, ...}):
%     new data from TLS, add it to buffer
%
%   handle_request(...):
%     extract line from buffer if one is complete
%
%   handle_line(...):
%     decode URL from line (i.e., Unicode, RFC-3986 percent escaping)
%
%   handle_parsed_url(...):
%     provide defaults for missing URL parts, such as port number
%
%   handle_url(...):
%     strip out requests for non-Gemini URLs, requests to proxy, etc
%
%   handle_gemini_url(...):
%     strip out Gemini requests unrelated to this server, normalize URL
%
%   handle_path(...):
%     strip out multiple leading slashes from path component of URL
%
%   handle_file(...):
%     strip out requests involving ".."
%
%   serve_file(...):
%     redirect requests for directories to index files; otherwise return
%     file contents if file exists
%
% All calls below handle_request return a response of type gemini_response().

-module(blizanci_gemini).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").
-behaviour(gen_server).
-behaviour(ranch_protocol).

-include("blizanci_types.hrl").

%% API to be called by other blizanci modules
-export([start_link/4]).
-export([verify_cert/3]).
-export([handle_line/3]).     % temporarily enabled for testing

%% API expected by gen_server callback behaviour
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).


%% types / constants / enums / config
-define(EMPTY_BUF, <<>>).
-define(PROTO, <<"gemini">>).
-define(CRLF, <<"\r\n">>).
-define(INDEX, "index.gemini").
-define(TIMEOUT_MS, 10000).
-define(MAX_REQUEST_BYTES, 4000).

-spec gemini_status(atom()) -> {integer(), binary()}.
gemini_status(request_too_long)      -> {59, <<"Request too long">>};
gemini_status(request_not_parsed)    -> {59, <<"Request not parsed">>};
gemini_status(proxy_refused)         -> {53, <<"Proxy request refused">>};
gemini_status(host_unrecognised)     -> {53, <<"Host unrecognised">>};
gemini_status(port_unrecognised)     -> {53, <<"Port unrecognised">>};
gemini_status(unrecognised_protocol) -> {59, <<"Protocol not recognised">>};
gemini_status(bad_unicode)           -> {59, <<"Bad unicode in request">>};
gemini_status(bad_filename)          -> {59, <<"Illegal filename">>};
gemini_status(bad_hostname)          -> {59, <<"Illegal hostname">>};
gemini_status(internal_server_error) -> {40, <<"Internal server error">>};
gemini_status(cgi_exec_error)        -> {40, <<"Gateway error">>};
gemini_status(file_not_found)        -> {51, <<"File not found">>};
gemini_status(cert_required)         -> {60, <<"Client certificate required">>};
gemini_status(permanent_redirect)    -> {31, <<"Moved permanently">>}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


-spec start_link(pid(), any(), any(), [any()]) -> {ok, pid()}.
start_link(Ref, Socket, Transport, Opts) ->
    proc_lib:start_link(?MODULE, init, [{Ref, Socket, Transport, Opts}]).


-spec verify_cert(
        OtpCert :: #'OTPCertificate'{},
        Event :: {'bad_cert', Reason :: atom() | {'revoked', atom()}} |
                 {'extension', #'Extension'{}} |
                 'valid' |
                 'valid_peer',
        InitialUserState :: term()
       ) -> {'valid', UserState :: term()} |
            {'fail', Reason :: term()} |
            {'unknown', UserState :: term()}.
verify_cert(_Cert, _Event, _InitialUserState) ->
    {valid, unknown_user}.


-spec init({pid(), any(), any(), [any()]}) -> {ok, pid()}.
init({Ref, Socket, Transport, Opts}) ->
    ok = proc_lib:init_ack({ok, self()}),
    ok = ranch:accept_ack(Ref),
    ok = activate(Transport, Socket),
    PC = ssl:peercert(Socket),
    Hostname = erlang:list_to_binary(proplists:get_value(hostname, Opts)),
    Port = proplists:get_value(port, Opts),
    Docroot = proplists:get_value(docroot, Opts),
    CGIroot = proplists:get_value(cgiroot, Opts),
    Config = #server_config{
                hostname=Hostname,
                port=Port,
                docroot=Docroot,
                cgiroot=CGIroot},
    State = #state{
               transport=Transport,
               socket=Socket,
               buffer=?EMPTY_BUF,
               config=Config,
               requested=false,
               cgi_proc=no_cgi,
               client_cert=PC},
    erlang:send_after(?TIMEOUT_MS, self(), timeout),
    gen_server:enter_loop(?MODULE, [], State).


handle_info({ssl, Socket, Payload}, State) ->
    {Buffer, Response} =
        try handle_request(Payload, State) of
            Result -> Result
        catch
            _ -> {<<"">>, {error_code, internal_server_error}}
        end,
    NewState = State#state{buffer=Buffer},
    Transport = State#state.transport,

    case activate(Transport, Socket) of
        ok -> case respond(Response, State) of
                  continue -> {noreply, NewState};
                  finished -> Transport:close(Socket),
                              {noreply, NewState};
                  {expect_cgi, Pid, OsPid} ->
                      NewerState = NewState#state{cgi_proc={Pid, OsPid, <<>>}},
                      {noreply, NewerState}
              end;
        {error, closed} ->
            {stop, normal, State};
        _ ->
            {stop, normal, State}
    end;

handle_info({tcp_closed, _Socket}, State) ->
    {stop, normal, State};

handle_info({tcp_error, _, Reason}, State) ->
    {stop, Reason, State};

handle_info(timeout, State) ->
    {stop, normal, State};

handle_info({ssl_closed, _SocketInfo}, State) ->
    CGIProc = State#state.cgi_proc,
    blizanci_cgi:cancel(CGIProc),
    {stop, normal, State};

handle_info({'DOWN', OsPid, process, Pid, Status}, State) ->
    {ExpectedPid, ExpectedOsPid, Buffer} = State#state.cgi_proc,
    ExpectedPid = Pid,
    ExpectedOsPid = OsPid,
    %ExitStatus = exec:status(Status),
    case Status of
        normal ->
            respond({cgi_output, Buffer}, State);
        {exit_status, St} ->
            RV = exec:status(St),
            lager:info("cgi process ended with non-zero status: ~p", [RV]),
            respond({error_code, cgi_exec_error}, State);
        St ->
            lager:info("cgi process terminated anomalously: ~p", [St]),
            respond({error_code, cgi_exec_error}, State)
    end,
    {stop, normal, State};

handle_info({stdout, OsPid, Msg}, State) ->
    {ExpectedPid, ExpectedOsPid, Buffer} = State#state.cgi_proc,
    ExpectedOsPid = OsPid,
    NewBuffer = erlang:iolist_to_binary([Buffer, Msg]),
    NewState = State#state{cgi_proc={ExpectedPid, ExpectedOsPid, NewBuffer}},
    {noreply, NewState};

handle_info({stderr, _OsPid, Msg}, State) ->
    lager:info("got errmsg ~p", [Msg]),
    {noreply, State};

handle_info(Msg, State) ->
    lager:debug("Received unrecognised message: ~p~n", [Msg]),
    {stop, normal, State}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


% This ceremony is necessary for telling the Erlang VM to monitor
% the socket for incoming data, and must be called each time the
% socket is to be read from.
-spec activate(atom(), inet:socket()) -> 'ok' | {'error', _}.
activate(Transport, Socket) ->
    Transport:setopts(Socket, [{active, once}]).


% Send a response back to the client, generally closing the connection
% if it is finished. If the client hasn't managed to send a whole request,
% do nothing.
-spec respond(gemini_response(), state()) -> gemini_session().
respond(none, _State) ->
    % don't hang up where only part of the URL + CRLF has been received
    continue;

respond({init_cgi, Pid, OsPid}, _State) ->
    {expect_cgi, Pid, OsPid};

respond({cgi_output, Msg}, #state{transport=Transport, socket=Socket}) ->
    Header = format_headers(20, <<"text/plain">>),
    Transport:send(Socket, [Header, Msg]),
    Transport:close(Socket),
    finished;

respond(hangup, _State) ->
    finished;

respond({file, MimeType, Filename},
        #state{transport=Transport, socket=Socket}) ->
    Header = format_headers(20, MimeType),
    Transport:send(Socket, Header),
    Transport:sendfile(Socket, Filename),
    finished;

respond({error_code, Code}, #state{transport=Transport, socket=Socket}) ->
    {ok, Msg} = format_error(Code),
    Transport:send(Socket, Msg),
    finished;

respond({redirect, Path}, State=#state{transport=Transport, socket=Socket}) ->
    Config = State#state.config,
    Meta = construct_local_url(Config, Path),
    {Code, _} = gemini_status(permanent_redirect),
    Msg = format_headers(Code, Meta),
    Transport:send(Socket, Msg),
    finished.


% Theoretically, a client could send its request very slowly, with
% parts of the URL arriving piecemeal; it could also send a massive
% blob of data all at once. We buffer data received from the client
% in State.buffer, and wait until a CRLF appears. The canonical case
% is of course that the CRLF appears the first time we ever receive
% data, rendering the buffer redundant.
-spec handle_request(binary(), state())
                    -> {binary(), gemini_response()}.
handle_request(Payload, #state{buffer=Buffer,
                               config=Config,
                               client_cert=Cert}) ->
    AllInput = erlang:iolist_to_binary([Buffer, Payload]),
    case binary:split(AllInput, ?CRLF) of
        [S] when size(S) > ?MAX_REQUEST_BYTES ->
            {<<>>, {error_code, request_too_long}};
        [_] ->
            {AllInput, none};
        [Line, Rest] ->
            R = handle_line(Line, Config, Cert),
            {Rest, R};
        _ ->
            lager:warning("Shouldn't get here"),
            {<<>>, hangup}
    end.


% Take the request line which has been received in full from the client
% and check that it's valid UTF8; if so, break it down into its URL parts
-spec handle_line(binary(), server_config(), term())
                 -> gemini_response().
handle_line(Cmd, _Config, _Cert) when is_binary(Cmd),
                                      size(Cmd) > 1024 ->
    {error_code, request_too_long};

handle_line(Cmd, Config, Cert) when is_binary(Cmd) ->
    Recoded = unicode:characters_to_binary(<<Cmd/binary>>, utf8),
    case Recoded of
        {error, _, _}      -> {error_code, bad_unicode};
        {incomplete, _, _} -> {error_code, bad_unicode};
        S ->
            blizanci_access:info("Request: ~p", [S]),
            case uri_string:parse(S) of
                {error, _, _} -> {error_code, request_not_parsed};
                URI -> handle_parsed_url(URI, Config, Cert)
            end
    end.

% Extract the parts of the URL, providing defaults where necessary
-spec handle_parsed_url(map(), server_config(), term()) -> gemini_response().
handle_parsed_url(URI, Config, Cert) ->
    try
        ReqHost = maps:get(host, URI, <<>>),
        Path = maps:get(path, URI, <<"/">>),
        Scheme = maps:get(scheme, URI, ?PROTO),
        ReqPort = maps:get(port, URI, Config#server_config.port),
        ReqPath = case Path of
                      <<>> -> <<"/">>;
                      P -> P
                  end,
        Query = maps:get(query, URI, <<>>),
        #{ scheme => Scheme,
           host => ReqHost,
           port => ReqPort,
           path => ReqPath,
           query => Query,
           client_cert => Cert
         }
    of
        Matches -> handle_url(Matches, Config)
    catch
        _ -> {error_code, request_not_parsed}
    end.


% Handle a request whose URL has been broken up thus:
%   [Scheme, Hostname, Port, Path]
-spec handle_url(map(), server_config()) -> gemini_response().
handle_url(#{ scheme := <<"gopher">> }, _) -> {error_code, proxy_refused};
handle_url(#{ scheme := <<"https">> }, _) -> {error_code, proxy_refused};
handle_url(#{ scheme := <<"http">> }, _) -> {error_code, proxy_refused};
handle_url(#{ scheme := ?PROTO } = URL, Config) ->
    handle_gemini_url(URL, Config);
handle_url(URI, _Config) ->
    lager:info("unrec: ~p", [URI]),
    {error_code, unrecognised_protocol}.


% Handle a request which has been determined to be a Gemini URL, but not
% necessarily one which should have come to this server (e.g., a proxy
% request)
-spec handle_gemini_url(map(), server_config()) -> gemini_response().
handle_gemini_url(Req=#{ host := Host, port := Port, path := Path},
                  Config=#server_config{hostname=Host, port=Port}) ->
    handle_path(uri_string:normalize(Path), Req, Config);

handle_gemini_url(#{ host := <<>>, port := Port },
                  #server_config{port=Port}) ->
    {error_code, bad_hostname};

handle_gemini_url(#{ port := Port },
                  #server_config{port=Port}) ->
    {error_code, host_unrecognised};

handle_gemini_url(#{ port := ReqPort },
                  #server_config{port=Port})
  when ReqPort =/= Port ->
    {error_code, port_unrecognised};

handle_gemini_url(_, _) -> {error_code, host_unrecognised}.



% Strip leading slash(es) from URL
-spec handle_path(binary(), map(), server_config()) -> gemini_response().
handle_path(<<$/, Trailing/binary>>, Req, Config) ->
    handle_path(Trailing, Req, Config);
handle_path(Path, Req, Config) ->
    handle_file(Path, Req, Config).


% Deal with ".." attempts
-spec handle_file(binary(), map(), server_config()) -> gemini_response().
handle_file(Path, Req, Config) when is_binary(Path) ->
    case string:split(Path, "..") of
        [_] -> serve(Path, Req, Config);
        [_, _] -> {error_code, bad_filename}
    end.


% Separate out CGI
-spec serve(binary(), map(), server_config()) -> gemini_response().
serve(_Pth = <<"cgi-bin/", Rest/binary>>, Req, Config) ->
    blizanci_cgi:serve(Rest, Req, Config);
serve(Path = <<"restricted/", _Rest/binary>>, Req, Config) ->
    serve_file(Path, Req, Config#server_config.docroot, restricted);
serve(Path = <<"private/", _Rest/binary>>, Req, Config) ->
    serve_file(Path, Req, Config#server_config.docroot, private);
serve(Path, Req, Config) ->
    serve_file(Path, Req, Config#server_config.docroot, public).


% private: certificate must be signed by a particular CA
% restricted: certificate must be presented
% public: no certificate requirement
-spec serve_file(binary(), map(), string(), authorisation())
                -> gemini_response().
serve_file(Path, _Req, Docroot, public) ->
    serve_file(Path, Docroot);
serve_file(Path, Req, Docroot, Auth) ->
    #{ client_cert := Cert } = Req,
    CertInfo = blizanci_x509:peercert_cn(Cert),
    serve_restricted_file(Path, Docroot, Auth, CertInfo).


-spec serve_restricted_file(binary(), string(), authorisation(),
                            any()) ->
                                   gemini_response().
serve_restricted_file(_Path, _Docroot, _Auth, error) ->
    {error_code, cert_required};
serve_restricted_file(Path, Docroot, Auth, {ok, CertInfo}) ->
    #{ common_name := Subject,
       issuer_common_name := Issuer } = CertInfo,
    lager:info("~p object requested, peercert: ~p/~p", [Auth, Subject, Issuer]),
    serve_file(Path, Docroot).


% If there's a valid file requested, then get its full path, so that
% it can be sendfile()'d back to the client. If it's a directory, redirect
% to an index file.
-spec serve_file(binary(), string()) -> gemini_response().
serve_file(Path, Docroot) ->
    Full = filename:join(Docroot, Path),
    case {filelib:is_dir(Full), filelib:is_regular(Full)} of
        {true, _} ->
            Redirect = filename:join(Path, ?INDEX),
            {redirect, Redirect};
        {false, true} ->
            MimeType = mime_type(Full),
            {file, MimeType, Full};
        _ ->
            {error_code, file_not_found}
    end.


% Look up the MIME type for a given filename. If the filename doesn't contain
% a ".", then assume it's text/gemini. If it contains a "." but isn't in
% the MIME types dataset, then assume it's application/octet-stream.
-spec mime_type(binary()) -> binary().
mime_type(Path) when is_binary(Path) ->
    case binary_to_list(filename:extension(Path)) of
        [] -> <<"text/gemini">>;
        [_Dot|Rest] -> Key = erlang:list_to_binary(Rest),
                      case blizanci_mimetypes:lookup(Key) of
                          notfound -> <<"application/octet-stream">>;
                          {ok, Result} -> Result
                      end
    end.


-spec format_headers(integer(), binary()) -> iolist().
format_headers(Code, Meta) when is_integer(Code), is_binary(Meta) ->
    Status = list_to_binary(integer_to_list(Code)),
    [Status, <<" ">>, Meta, ?CRLF].


-spec format_error(atom()) -> {'ok', iolist()}.
format_error(Code) when is_atom(Code) ->
    {GeminiStatus, Explanation} = gemini_status(Code),
    Headers = format_headers(GeminiStatus, Explanation),
    {ok, Headers}.


-spec construct_local_url(server_config(), binary()) -> binary().
construct_local_url(Config, Path) ->
    construct_url(?PROTO,
                  Config#server_config.hostname,
                  Config#server_config.port,
                  Path).

-spec construct_url(binary(), binary(), integer(), binary()) -> binary().
construct_url(Scheme, Hostname, Port, Path) ->
    uri_string:recompose(#{ scheme => Scheme,
                            host => Hostname,
                            port => Port,
                            path => Path }).



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Tests.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


handle_line_test_data() ->
    [
     {{file, <<"text/gemini">>, <<"/bin/which">>},
      <<"gemini://this.host.dev/which">>},

     {{file, <<"text/gemini">>, <<"/bin/which">>},
      <<"gemini://this.host.dev:1965/which">>}
    ].

handle_line_test_() ->
    [ ?_assertEqual(Expected, handle_line(TestInput,
                                          #server_config{
                                             hostname= <<"this.host.dev">>,
                                             port= 1965,
                                             docroot="/bin",
                                             cgiroot="/cgi-bin"},
                                          {error, no_peercert})) ||
        {Expected, TestInput} <- handle_line_test_data() ].
