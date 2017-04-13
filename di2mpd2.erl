%%%-------------------------------------------------------------------
%%% File    : di2mpd2.erl
%%% Author  :  <tom@desu>
%%% Description : 
%%%
%%% Created : 19 Dec 2009 by  <tom@desu>
%%%-------------------------------------------------------------------
-module(di2mpd2).

-export([start/0,init/1, loop/1, loop/2]).
-export([repeated_init/1]).
-export([is_ripping/0]).
-export([get_song/1, song_to_address/3]).


start() ->
        case is_ripping() of
                false ->
                        status("Streamripper was not found!");
                _ ->
                        status("Streamripper has been detected!")
                end,
        spawn(di2mpd2, init, [50]).

init(Repeated) ->
        put(playlist, []),
        inets:start(),
        receive nothing -> nothing after 500 -> nothing end,
        RepeatServ = spawn(?MODULE, repeated_init, [Repeated]),
        loop(RepeatServ).

loop(RepeatServ) ->
        ?MODULE:loop(RepeatServ, 33000).

loop(RepeatServ, Speed) ->
        receive
                {current, _, _, _, []} ->
                        skip;
                {current, Track, Artist,Title,Address} ->
                        case is_complete_rip(Address) of
                                true ->
                                        RepeatServ ! {check, self(), Track},
                                        receive
                                                {unique, previous} ->
                                                        status("Waiting for next track!", r);
                                                {unique, true} ->
                                                        %This is where the track gets added
                                                        R = os:cmd(io_lib:format("mpc add \"~s\"", [lists:subtract(Address, "\n")])),
                                                        status("Adding:  " ++ Track++" ("++lists:subtract(R,"\n")++")");
                                                {unique, false} ->
                                                        status("Already heard this track: "++ Track)
                                        end;                                    
                                false ->
                                        receive
                                                noescape ->
                                                        skip
                                        after Speed ->
                                                %% this avoids infinite loops when stream ripper has been stopped
                                                case (is_ripping()) of
                                                        {true, _ } ->
                                                                case check_ctime(Artist,Title) of
                                                                        true ->
                                                                                status("Ripping: " ++ Track, r),
                                                                                search({Track, Artist, Title});
                                                                        _ ->
                                                                                status("Stopped: " ++ Track)
                                                                end;
                                                        _ ->
                                                                skip
                                                end
                                        end
                        end;
                _ ->
                        skip
        %% Check if a new track is playing
        after Speed ->
                        case (is_ripping()) of 
                                {true, Station } ->
                                        has_station_changed(Station),
                                        search(get_song(get_stream_log()));
                                {false} ->
                                        status("Streamripper is not running", r)                                
                        end
        end,
        ?MODULE:loop(RepeatServ, Speed).

check_ctime(Artist,Title) ->
        case os:cmd("find /media/music/ -type f -name \"*"++fix_find_string(Artist)++"* - *"++fix_find_string(Title)++"*.mp3\" -cmin -3") of
                [] ->
                        false;
                _ ->
                        true
        end.

fix_find_string(String) ->
        re:replace(String, "\\Q.\\E","-",[global, multiline, {return, list}]).

is_complete_rip(Address) ->
        re:run(Address, "incomplete") == nomatch.

get_inotify_log() ->
        lists:subtract(
                os:cmd("tail -1 /tmp/streamripper.inotify.out")
        , "\n").

get_stream_log() ->
        lists:subtract(
                os:cmd("sed 's|\\r|\\n|g' /tmp/streamripper.out | strings | tail -n 1 | sed -E -e s/'\[[a-z. ]+\] '/''/g -e s/' \[[0-9. ]+[GMkb]+\]'/''/g")
        , "\n").


%% locate the song with mpd
search({error, Message}) ->
        {error, Message};
search({Track, Artist, Title}) ->
        self() ! {current, Track, Artist, Title, song_to_address(Artist, Title, Track)};
search({Track}) ->
        status("Splitting failed for: " ++ Track).


song_to_address(Artist, Title, _) ->
        lists:subtract( 
                os:cmd(io_lib:format("mpc update streamripper > /dev/null; sleep 1; mpc search artist \"~s\" title \"~s\" | head -1", [Artist, Title]))
                , "\n").


%% get the song into a track artist format
get_song({error, Message}) ->
        {error, Message};
get_song(Track) ->
        case re:run(Track, "([^-]+)(-+.+)* - (.+)") of
                {match, [_, {AS, AE},_, {TS, TE}]} ->
                        {Track, string:strip(string:sub_string(Track, AS+1, AS+AE)),
                         string:strip(string:sub_string(Track, TS+1, TS+TE))
                         };
                _ ->
                        {Track}
        end.


%% Deals with status messages
status(NewStatus, r) ->
        clear_line(get(last)),
        put(last, NewStatus),
        io:format("~p ~p ~p ~s\r", [self(),time(), date(), NewStatus]).


status(NewStatus) ->
        case get(last) of
                NewStatus ->
                        skip;
                _ ->
                        put(last, NewStatus),
                        io:format("~p ~p ~p ~s~n", [self(),time(), date(), NewStatus])
        end.



has_station_changed(Station) ->
        case get(station) of
                Station ->
                        skip;
                _ ->
                        put(station, Station),
                        status("Station changed to "++ atom_to_list(Station))
        end.

%% Repeat server saves playlist and notifies that song has been repeated within
%% a certain number of plays.
repeated_init(Max) ->
        io:format("~p ~p ~p Repeat server is running~n", [self(),time(), date()]),
        Songs = lists:sublist(load("/var/disync/songs.bin"),Max),
        io:format("~p ~p ~p ~b songs loaded~n", [self(),time(), date(), string:len(Songs)]),
        repeated_loop(Max, Songs).

repeated_loop(Max, List) ->
        save("/var/disync/songs.bin", List),
        receive
                {add, Name} ->
                        repeated_loop(Max, lists:sublist([Name]++List, Max));
                {check, Pid, Name} ->
                        case (lists:sublist(List, 1) == [Name]) of
                                true ->
                                        Pid ! {unique, previous},
                                        repeated_loop(Max, List);
                                false ->
                                        Pid ! {unique, lists:member(Name, List)==false},
                                        repeated_loop(Max, lists:sublist([Name]++List, Max))
                        end                     
        end.
        

is_ripping() ->
        case os:cmd("ps eat | grep -o -E \"streamripper http://(.+:.+@)?.+:[0-9]+/[a-z]+\" | grep -E -o \"[a-z]+$\"") of
                [] ->
                        {false};
                Any ->
                        {true,erlang:list_to_atom(lists:subtract(Any, "\n"))}
        end.


clear_line(undefined) ->
        ok;
clear_line(Len) ->
        io:format("~s\r", [[" " || _ <- lists:seq(1,string:len(Len))]]).



save(Filename, Terms) ->
        file:write_file(Filename,
               term_to_binary(Terms)).

load(Filename) ->
    case file:read_file(Filename) of
        {ok, Terms} ->
            binary_to_term(Terms);
        _ ->
            []
    end.
