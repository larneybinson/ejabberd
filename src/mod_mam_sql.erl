%%%-------------------------------------------------------------------
%%% File    : mod_mam_sql.erl
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Created : 15 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2020   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(mod_mam_sql).


-behaviour(mod_mam).

%% API
-export([init/2, remove_user/2, remove_room/3, delete_old_messages/3,
	 extended_fields/0, store/8, write_prefs/4, get_prefs/2, select/7, export/1, remove_from_archive/3,
	 is_empty_for_user/2, is_empty_for_room/3, select_with_mucsub/6]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("xmpp.hrl").
-include("mod_mam.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").
-include("mod_muc_room.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    ok.

remove_user(LUser, LServer) ->
    ejabberd_sql:sql_query(
      LServer,
      ?SQL("delete from archive where username=%(LUser)s and %(LServer)H")),
    ejabberd_sql:sql_query(
      LServer,
      ?SQL("delete from archive_prefs where username=%(LUser)s and %(LServer)H")).

remove_room(LServer, LName, LHost) ->
    LUser = jid:encode({LName, LHost, <<>>}),
    remove_user(LUser, LServer).

remove_from_archive(LUser, LServer, none) ->
    case ejabberd_sql:sql_query(LServer,
				?SQL("delete from archive where username=%(LUser)s and %(LServer)H")) of
	{error, Reason} -> {error, Reason};
	_ -> ok
    end;
remove_from_archive(LUser, LServer, WithJid) ->
    Peer = jid:encode(jid:remove_resource(WithJid)),
    case ejabberd_sql:sql_query(LServer,
				?SQL("delete from archive where username=%(LUser)s and %(LServer)H and bare_peer=%(Peer)s")) of
	{error, Reason} -> {error, Reason};
	_ -> ok
    end.

delete_old_messages(ServerHost, TimeStamp, Type) ->
    TS = now_to_usec(TimeStamp),
    case Type of
        all ->
            ejabberd_sql:sql_query(
              ServerHost,
              ?SQL("delete from archive"
                   " where timestamp < %(TS)d and %(ServerHost)H"));
        _ ->
            SType = misc:atom_to_binary(Type),
            ejabberd_sql:sql_query(
              ServerHost,
              ?SQL("delete from archive"
                   " where timestamp < %(TS)d"
                   " and kind=%(SType)s"
                   " and %(ServerHost)H"))
    end,
    ok.

extended_fields() ->
    [{withtext, <<"">>}].

store(Pkt, LServer, {LUser, LHost}, Type, Peer, Nick, _Dir, TS) ->
    SUser = case Type of
		chat -> LUser;
		groupchat -> jid:encode({LUser, LHost, <<>>})
	    end,
    BarePeer = jid:encode(
		 jid:tolower(
		   jid:remove_resource(Peer))),
    LPeer = jid:encode(
	      jid:tolower(Peer)),
    Body = fxml:get_subtag_cdata(Pkt, <<"body">>),
    SType = misc:atom_to_binary(Type),
    SqlType = ejabberd_option:sql_type(LHost),
    XML = case mod_mam_opt:compress_xml(LServer) of
	      true ->
		  J1 = case Type of
			      chat -> jid:encode({LUser, LHost, <<>>});
			      groupchat -> SUser
			  end,
		  xml_compress:encode(Pkt, J1, LPeer);
	      _ ->
		  fxml:element_to_binary(Pkt)
	  end,
	case SqlType of
	  mssql -> case ejabberd_sql:sql_query(
	           LServer,
	           ?SQL_INSERT(
	              "archive",
	              ["username=%(SUser)s",
	               "server_host=%(LServer)s",
	               "timestamp=%(TS)d",
	               "peer=%(LPeer)s",
	               "bare_peer=%(BarePeer)s",
	               "xml=N%(XML)s",
	               "txt=N%(Body)s",
	               "kind=%(SType)s",
	               "nick=%(Nick)s"])) of
		{updated, _} ->
		    ok;
		Err ->
		    Err
	    end;
	    _ -> case ejabberd_sql:sql_query(
	           LServer,
	           ?SQL_INSERT(
	              "archive",
	              ["username=%(SUser)s",
	               "server_host=%(LServer)s",
	               "timestamp=%(TS)d",
	               "peer=%(LPeer)s",
	               "bare_peer=%(BarePeer)s",
	               "xml=%(XML)s",
	               "txt=%(Body)s",
	               "kind=%(SType)s",
	               "nick=%(Nick)s"])) of
		{updated, _} ->
		    ok;
		Err ->
		    Err
	    end
	end.

write_prefs(LUser, _LServer, #archive_prefs{default = Default,
					   never = Never,
					   always = Always},
	    ServerHost) ->
    SDefault = erlang:atom_to_binary(Default, utf8),
    SAlways = misc:term_to_expr(Always),
    SNever = misc:term_to_expr(Never),
    case ?SQL_UPSERT(
            ServerHost,
            "archive_prefs",
            ["!username=%(LUser)s",
             "!server_host=%(ServerHost)s",
             "def=%(SDefault)s",
             "always=%(SAlways)s",
             "never=%(SNever)s"]) of
	ok ->
	    ok;
	Err ->
	    Err
    end.

get_prefs(LUser, LServer) ->
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("select @(def)s, @(always)s, @(never)s from archive_prefs"
                " where username=%(LUser)s and %(LServer)H")) of
	{selected, [{SDefault, SAlways, SNever}]} ->
	    Default = erlang:binary_to_existing_atom(SDefault, utf8),
	    Always = ejabberd_sql:decode_term(SAlways),
	    Never = ejabberd_sql:decode_term(SNever),
	    {ok, #archive_prefs{us = {LUser, LServer},
		    default = Default,
		    always = Always,
		    never = Never}};
	_ ->
	    error
    end.

select(LServer, JidRequestor, #jid{luser = LUser} = JidArchive,
       MAMQuery, RSM, MsgType, Flags) ->
    User = case MsgType of
	       chat -> LUser;
	       _ -> jid:encode(JidArchive)
	   end,
    {Query, CountQuery} = make_sql_query(User, LServer, MAMQuery, RSM, none),
    do_select_query(LServer, JidRequestor, JidArchive, RSM, MsgType, Query, CountQuery, Flags).

-spec select_with_mucsub(binary(), jid(), jid(), mam_query:result(),
			     #rsm_set{} | undefined, all | only_count | only_messages) ->
				{[{binary(), non_neg_integer(), xmlel()}], boolean(), non_neg_integer()} |
				{error, db_failure}.
select_with_mucsub(LServer, JidRequestor, #jid{luser = LUser} = JidArchive,
		   MAMQuery, RSM, Flags) ->
    Extra = case gen_mod:db_mod(LServer, mod_muc) of
		mod_muc_sql ->
		    subscribers_table;
		_ ->
		    SubRooms = case mod_muc_admin:find_hosts(LServer) of
				   [First|_] ->
				       case mod_muc:get_subscribed_rooms(First, JidRequestor) of
					   {ok, L} -> L;
					   {error, _} -> []
				       end;
				   _ ->
				       []
			       end,
		    [jid:encode(Jid) || {Jid, _} <- SubRooms]
	    end,
    {Query, CountQuery} = make_sql_query(LUser, LServer, MAMQuery, RSM, Extra),
    do_select_query(LServer, JidRequestor, JidArchive, RSM, chat, Query, CountQuery, Flags).

do_select_query(LServer, JidRequestor, #jid{luser = LUser} = JidArchive, RSM,
		MsgType, Query, CountQuery, Flags) ->
    % TODO from XEP-0313 v0.2: "To conserve resources, a server MAY place a
    % reasonable limit on how many stanzas may be pushed to a client in one
    % request. If a query returns a number of stanzas greater than this limit
    % and the client did not specify a limit using RSM then the server should
    % return a policy-violation error to the client." We currently don't do this
    % for v0.2 requests, but we do limit #rsm_in.max for v0.3 and newer.
    QRes = case Flags of
		   all ->
		       {ejabberd_sql:sql_query(LServer, Query), ejabberd_sql:sql_query(LServer, CountQuery)};
		   only_messages ->
		       {ejabberd_sql:sql_query(LServer, Query), {selected, ok, [[<<"0">>]]}};
		   only_count ->
		       {{selected, ok, []}, ejabberd_sql:sql_query(LServer, CountQuery)}
	       end,
    case QRes of
	{{selected, _, Res}, {selected, _, [[Count]]}} ->
	    {Max, Direction, _} = get_max_direction_id(RSM),
	    {Res1, IsComplete} =
	    if Max >= 0 andalso Max /= undefined andalso length(Res) > Max ->
		if Direction == before ->
		    {lists:nthtail(1, Res), false};
		    true ->
			{lists:sublist(Res, Max), false}
		end;
		true ->
		    {Res, true}
	    end,
	    MucState = #state{config = #config{anonymous = true}},
	    JidArchiveS = jid:encode(JidArchive),
	    {lists:flatmap(
		fun([TS, XML, PeerBin, Kind, Nick]) ->
		    case make_archive_el(JidArchiveS, TS, XML, PeerBin, Kind, Nick,
					 MsgType, JidRequestor, JidArchive) of
			{ok, El} ->
			    [{TS, binary_to_integer(TS), El}];
			{error, _} ->
			    []
		    end;
		   ([User, TS, XML, PeerBin, Kind, Nick]) when User == LUser ->
		       case make_archive_el(JidArchiveS, TS, XML, PeerBin, Kind, Nick,
					    MsgType, JidRequestor, JidArchive) of
			   {ok, El} ->
			       [{TS, binary_to_integer(TS), El}];
			   {error, _} ->
			       []
		       end;
		   ([User, TS, XML, PeerBin, Kind, Nick]) ->
		       case make_archive_el(User, TS, XML, PeerBin, Kind, Nick,
					    {groupchat, member, MucState}, JidRequestor,
					    jid:decode(User)) of
			   {ok, El} ->
			       mod_mam:wrap_as_mucsub([{TS, binary_to_integer(TS), El}],
						      JidRequestor);
			   {error, _} ->
			       []
		       end
		end, Res1), IsComplete, binary_to_integer(Count)};
	_ ->
	    {[], false, 0}
    end.

export(_Server) ->
    [{archive_prefs,
      fun(Host, #archive_prefs{us =
                {LUser, LServer},
                default = Default,
                always = Always,
                never = Never})
          when LServer == Host ->
                SDefault = erlang:atom_to_binary(Default, utf8),
                SAlways = misc:term_to_expr(Always),
                SNever = misc:term_to_expr(Never),
                [?SQL_INSERT(
                    "archive_prefs",
                    ["username=%(LUser)s",
                     "server_host=%(LServer)s",
                     "def=%(SDefault)s",
                     "always=%(SAlways)s",
                     "never=%(SNever)s"])];
          (_Host, _R) ->
              []
      end},
     {archive_msg,
      fun(Host, #archive_msg{us ={LUser, LServer},
                id = _ID, timestamp = TS, peer = Peer,
                type = Type, nick = Nick, packet = Pkt})
          when LServer == Host ->
                TStmp = now_to_usec(TS),
                SUser = case Type of
                      chat -> LUser;
                      groupchat -> jid:encode({LUser, LServer, <<>>})
                    end,
                BarePeer = jid:encode(jid:tolower(jid:remove_resource(Peer))),
                LPeer = jid:encode(jid:tolower(Peer)),
                XML = fxml:element_to_binary(Pkt),
                Body = fxml:get_subtag_cdata(Pkt, <<"body">>),
                SType = misc:atom_to_binary(Type),
                SqlType = ejabberd_option:sql_type(Host),
                case SqlType of
	                mssql -> [?SQL_INSERT(
	                    "archive",
	                    ["username=%(SUser)s",
	                     "server_host=%(LServer)s",
	                     "timestamp=%(TStmp)d",
	                     "peer=%(LPeer)s",
	                     "bare_peer=%(BarePeer)s",
	                     "xml=N%(XML)s",
	                     "txt=N%(Body)s",
	                     "kind=%(SType)s",
	                     "nick=%(Nick)s"])];
	                _ -> [?SQL_INSERT(
	                    "archive",
	                    ["username=%(SUser)s",
	                     "server_host=%(LServer)s",
	                     "timestamp=%(TStmp)d",
	                     "peer=%(LPeer)s",
	                     "bare_peer=%(BarePeer)s",
	                     "xml=%(XML)s",
	                     "txt=%(Body)s",
	                     "kind=%(SType)s",
	                     "nick=%(Nick)s"])]
		            end;
         (_Host, _R) ->
              []
      end}].

is_empty_for_user(LUser, LServer) ->
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("select @(1)d from archive"
		" where username=%(LUser)s and %(LServer)H limit 1")) of
	{selected, [{1}]} ->
	    false;
	_ ->
	    true
    end.

is_empty_for_room(LServer, LName, LHost) ->
    LUser = jid:encode({LName, LHost, <<>>}),
    is_empty_for_user(LUser, LServer).

%%%===================================================================
%%% Internal functions
%%%===================================================================
now_to_usec({MSec, Sec, USec}) ->
    (MSec*1000000 + Sec)*1000000 + USec.

usec_to_now(Int) ->
    Secs = Int div 1000000,
    USec = Int rem 1000000,
    MSec = Secs div 1000000,
    Sec = Secs rem 1000000,
    {MSec, Sec, USec}.

make_sql_query(User, LServer, MAMQuery, RSM, ExtraUsernames) ->
    Start = proplists:get_value(start, MAMQuery),
    End = proplists:get_value('end', MAMQuery),
    With = proplists:get_value(with, MAMQuery),
    WithText = proplists:get_value(withtext, MAMQuery),
    {Max, Direction, ID} = get_max_direction_id(RSM),
    ODBCType = ejabberd_option:sql_type(LServer),
    ToString = fun(S) -> ejabberd_sql:to_string_literal(ODBCType, S) end,
    LimitClause = if is_integer(Max), Max >= 0, ODBCType /= mssql ->
			  [<<" limit ">>, integer_to_binary(Max+1)];
		     true ->
			  []
		  end,
    TopClause = if is_integer(Max), Max >= 0, ODBCType == mssql ->
			  [<<" TOP ">>, integer_to_binary(Max+1)];
		     true ->
			  []
		  end,
    WithTextClause = if is_binary(WithText), WithText /= <<>> ->
			     [<<" and match (txt) against (">>,
			      ToString(WithText), <<")">>];
			true ->
			     []
		     end,
    WithClause = case catch jid:tolower(With) of
		     {_, _, <<>>} ->
			 [<<" and bare_peer=">>,
			  ToString(jid:encode(With))];
		     {_, _, _} ->
			 [<<" and peer=">>,
			  ToString(jid:encode(With))];
		     _ ->
			 []
		 end,
    PageClause = case catch binary_to_integer(ID) of
		     I when is_integer(I), I >= 0 ->
			 case Direction of
			     before ->
				 [<<" AND timestamp < ">>, ID];
			     'after' ->
				 [<<" AND timestamp > ">>, ID];
			     _ ->
				 []
			 end;
		     _ ->
			 []
		 end,
    StartClause = case Start of
		      {_, _, _} ->
			  [<<" and timestamp >= ">>,
			   integer_to_binary(now_to_usec(Start))];
		      _ ->
			  []
		  end,
    EndClause = case End of
		    {_, _, _} ->
			[<<" and timestamp <= ">>,
			 integer_to_binary(now_to_usec(End))];
		    _ ->
			[]
		end,
    SUser = ToString(User),
    SServer = ToString(LServer),

    HostMatch = case ejabberd_sql:use_new_schema() of
		    true ->
			[<<" and server_host=", SServer/binary>>];
		    _ ->
			<<"">>
		end,

    {UserSel, UserWhere} = case ExtraUsernames of
			       Users when is_list(Users) ->
				   EscUsers = [ToString(U) || U <- [User | Users]],
				   {<<" username,">>,
				    [<<" username in (">>, str:join(EscUsers, <<",">>), <<")">>]};
			       subscribers_table ->
				   SJid = ToString(jid:encode({User, LServer, <<>>})),
				   RoomName = case ODBCType of
						  sqlite ->
						      <<"room || '@' || host">>;
						  _ ->
						      <<"concat(room, '@', host)">>
					      end,
				   {<<" username,">>,
				    [<<" (username = ">>, SUser,
					<<" or username in (select ">>, RoomName,
					  <<" from muc_room_subscribers where jid=">>, SJid, HostMatch, <<"))">>]};
			       _ ->
				   {<<>>, [<<" username=">>, SUser]}
			   end,

    Query = [<<"SELECT ">>, TopClause, UserSel,
	     <<" timestamp, xml, peer, kind, nick"
	       " FROM archive WHERE">>, UserWhere, HostMatch,
	     WithClause, WithTextClause,
	     StartClause, EndClause, PageClause],

    QueryPage =
	case Direction of
	    before ->
		% ID can be empty because of
		% XEP-0059: Result Set Management
		% 2.5 Requesting the Last Page in a Result Set
		[<<"SELECT">>, UserSel, <<" timestamp, xml, peer, kind, nick FROM (">>,
		 Query, <<" ORDER BY timestamp DESC ">>,
		 LimitClause, <<") AS t ORDER BY timestamp ASC;">>];
	    _ ->
		[Query, <<" ORDER BY timestamp ASC ">>,
		 LimitClause, <<";">>]
	end,
    {QueryPage,
     [<<"SELECT COUNT(*) FROM archive WHERE ">>, UserWhere,
      HostMatch, WithClause, WithTextClause,
      StartClause, EndClause, <<";">>]}.

-spec get_max_direction_id(rsm_set() | undefined) ->
				  {integer() | undefined,
				   before | 'after' | undefined,
				   binary()}.
get_max_direction_id(RSM) ->
    case RSM of
	#rsm_set{max = Max, before = Before} when is_binary(Before) ->
	    {Max, before, Before};
	#rsm_set{max = Max, 'after' = After} when is_binary(After) ->
	    {Max, 'after', After};
	#rsm_set{max = Max} ->
	    {Max, undefined, <<>>};
	_ ->
	    {undefined, undefined, <<>>}
    end.

-spec make_archive_el(binary(), binary(), binary(), binary(), binary(),
		      binary(), _, jid(), jid()) ->
			     {ok, xmpp_element()} | {error, invalid_jid |
						     invalid_timestamp |
						     invalid_xml}.
make_archive_el(User, TS, XML, Peer, Kind, Nick, MsgType, JidRequestor, JidArchive) ->
    case xml_compress:decode(XML, User, Peer) of
	#xmlel{} = El ->
	    try binary_to_integer(TS) of
		TSInt ->
		    try jid:decode(Peer) of
			PeerJID ->
			    Now = usec_to_now(TSInt),
			    PeerLJID = jid:tolower(PeerJID),
			    T = case Kind of
				    <<"">> -> chat;
				    null -> chat;
				    _ -> misc:binary_to_atom(Kind)
				end,
			    mod_mam:msg_to_el(
			      #archive_msg{timestamp = Now,
					   id = TS,
					   packet = El,
					   type = T,
					   nick = Nick,
					   peer = PeerLJID},
			      MsgType, JidRequestor, JidArchive)
		    catch _:{bad_jid, _} ->
			    ?ERROR_MSG("Malformed 'peer' field with value "
				       "'~ts' detected for user ~ts in table "
				       "'archive': invalid JID",
				       [Peer, jid:encode(JidArchive)]),
			    {error, invalid_jid}
		    end
	    catch _:_ ->
		    ?ERROR_MSG("Malformed 'timestamp' field with value '~ts' "
			       "detected for user ~ts in table 'archive': "
			       "not an integer",
			       [TS, jid:encode(JidArchive)]),
		    {error, invalid_timestamp}
	    end;
	{error, {_, Reason}} ->
	    ?ERROR_MSG("Malformed 'xml' field with value '~ts' detected "
		       "for user ~ts in table 'archive': ~ts",
		       [XML, jid:encode(JidArchive), Reason]),
	    {error, invalid_xml}
    end.
