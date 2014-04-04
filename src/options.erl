%%%=========================================================================
%%%                                 LICENSE
%%%=========================================================================
%%%
%%%  This program is free software; you can redistribute it and/or modify
%%%  it under the terms of the GNU General Public License as published by
%%%  the Free Software Foundation; either version 2 of the License, or
%%%  (at your option) any later version.
%%%
%%%  This program is distributed in the hope that it will be useful,
%%%  but WITHOUT ANY WARRANTY; without even the implied warranty of
%%%  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%%  GNU Library General Public License for more details.
%%%
%%%  You should have received a copy of the GNU General Public License
%%%  along with this program; if not, write to the Free Software
%%%  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%=========================================================================

%%%=========================================================================
%%%                                  META
%%%=========================================================================
%%% @author Joel Ericson <joel.mikael.ericson@gmail.com>
%%%
%%% @copyright Copylefted using some GNU license or other.
%%%
%%% @doc A server that handles lookups of config values that are either in the file name given to start_link orin application:get_env.
%%%      options:get/2 returns like application:get_env.
%%%      values in the config file have precedence over the values in application:get_env.

-module(options).
-behaviour(gen_server).
-behaviour(application).

-type tree_thing()::{Key::term(),Val::term(),tree_thing(),tree_thing()}|nil.
-type gb_tree()::{non_neg_integer(),tree_thing()}.

-record(state,{
        config_files=[]::string(),
        config_options={0,nil}::gb_tree(),
        set_options={0,nil}::gb_tree(),
        module_syms=[]::[{SubModule::module(),AppModule::module()}]
        }).
        



-include_lib("newdebug/include/debug.hrl").
% application
-export([
        start/2
        ,stop/1]).

% gen_server
-export([init/1
         ,start_link/0
         ,start_link/1
         ,terminate/2
         ,code_change/3
         ,handle_info/2
        ]).
% Debugging
-export([
    get_all/0
    ,parse_line/2
        ]).

% Official        
-export([get/2
        ,mget/2
        ,rehash/0
        %,set_config/1
        %,has_config/0
        %,get_config/0
        ]).
% TODO
 -export([
%       set_configs/1,
%       list_configs/1,
%       append_config/1,
%       prepend_config/1,
%       remove_config/1,
       set/3
    ]).

% TODO: More than one config file...
-export([handle_call/3,handle_cast/2]).

-ifndef(CONFIG_NAME).
-define(CONFIG_NAME,".attrfsrc").
-endif.

start(_,_) ->
    options_sup:start_link().

stop(_State) ->
    ok.

start_link() ->
    case init:get_argument(config_file) of
        {ok,[Files]} ->
            ?DEB1(2,"No config file specified, using -config_file"),
            gen_server:start_link({local,?MODULE},?MODULE,Files,[]);
        error ->
            ?DEB1(2,"Neither -config_file nor config file specified, starting without config file."),
            gen_server:start_link({local,?MODULE},?MODULE,[],[])
    end.


start_link(ConfigNames) -> 
  gen_server:start_link({local,?MODULE},?MODULE,ConfigNames,[]).

init(ConfigNames) ->
    CN=lists:map(fun fix_home/1,ConfigNames),
    Options=lists:foldr(fun(Config,Tree) -> rehash_(Config,Tree) end,gb_trees:empty(),CN),
    {ok,#state{config_files=CN,config_options=Options}}.

fix_home([$~,$/|Name]) ->
    [os:getenv("HOME"),"/",Name];

fix_home(A) -> A.


rehash_(ConfigName,TreeAcc) ->
    try 
        case file:open(ConfigName,[read,raw]) of
            {ok,ConfigFile} ->
                % Read options from config file
                Options=readfile(ConfigFile),
                file:close(ConfigFile),
                ?DEBL({options,9},"Options: ~n ~p",[Options]),
                {ParsedOpts,_}=lists:mapfoldr(fun(X,Module)-> parse_line(X,Module) end,[],Options),
                ?DEBL({options,9},"Parsed: ~n ~p",[ParsedOpts]),
                ParsedTree=make_tree(ParsedOpts,TreeAcc),
                ParsedTree;

            Error ->
                ?DEBL({err,1},"Options file could not be read! Options only taken from environment file (~s ~w)",[lists:flatten(ConfigName),Error]),
                gb_trees:empty()
        end
    catch
        _L:_E ->
            ?DEBL({err,1},"Options file could not be read! Options only taken from environment file (~s ~w ~w)",[lists:flatten(ConfigName),_L,_E]),
            gb_trees:empty()
    end.

make_tree([],Acc) -> Acc;
make_tree([[]|As],Acc) -> make_tree(As,Acc); % Comment or empty line.
make_tree([{Mod,AKey,AVal}|As],Acc) ->
    case gb_trees:lookup(Mod,Acc) of
        {value,Tree} ->
            case gb_trees:lookup(AKey,Tree) of
                {value,{string,AVal0}} -> 
                    make_tree(As,
                              gb_trees:enter(Mod,
                                             gb_trees:enter(AKey,{list,[AVal,AVal0]},Tree),
                                             Acc)
                             );
                {value,{list,AList}} -> 
                    make_tree(As,
                              gb_trees:enter(Mod,
                                             gb_trees:enter(AKey,{list,[AVal|AList]},Tree),
                                             Acc)
                             );
                none -> 
                    make_tree(As,
                              gb_trees:enter(Mod,
                                             gb_trees:insert(AKey,{string,AVal},Tree),
                                             Acc)
                             )
            end;
        none ->
            NewTree=gb_trees:insert(AKey,{string,AVal},gb_trees:empty()),
            make_tree(As,gb_trees:insert(Mod,NewTree,Acc))
    end.

parse_line([],Mod) -> {[],Mod};
% empty lines
parse_line("\n",Mod) -> {[],Mod};
% commented lines
parse_line([$%|_],Mod) -> {[],Mod};
% bash commented lines
parse_line([$#|_],Mod) -> {[],Mod};
parse_line(Line,Mod) ->
    StrippedLine=hd(string:tokens(Line,"\n")),
    ?DEBL({options,1},"Parsing \"~s\"",[StrippedLine]),
    First=hd(StrippedLine),
    {Last,Elddim}=lists:split(1,lists:reverse(tl(StrippedLine))),
    Middle=lists:reverse(Elddim),
    case {First,Middle,Last} of
        {$[,NewMod,$]} ->
            ?DEBL(3,"parsing app/module header",[]),
            {[],NewMod};
        % TODO
        %{${,$}} ->
            %?DEBL(3,"parsing app/module header",[]),
            %[];
        _ ->
            case string:tokens(StrippedLine,":") of
                [NoColon] ->
                    ?DEBL(5,"Looking for ; in \"~s\"",[NoColon]),
                    case string:tokens(NoColon,";") of
                        [Head|Tail] ->
                            RealTail=string:join(Tail,";"),
                            ?DEBL(5,"Split: ~p ~p",[Head,RealTail]),
                            HeadAtom=list_to_atom(replace(Head,$ ,$_)),
                            Tails = string:tokens(RealTail," "),
                            ?DEBL(5,"Tokens: ~p",[Tails]),
                            WaggingTails = lists:map(fun fix_home/1,Tails),
                            FrozenTails = list_to_tuple(WaggingTails),
                            {{Mod,HeadAtom,FrozenTails},Mod};
                        _BogusLine ->
                            {[],Mod}

                    end;
                [Head|Tail] ->
                    A={Mod,list_to_atom(replace(Head,$ ,$_)),fix_home(string:strip(string:join(Tail,":")))},
                    ?DEBL({options,3},"Returning ~p",[A]),
                    {A,Mod}
            end
    end.


replace([],_B,_C) -> [];
replace([A|Str],B,C) when A == B ->
     [C|replace(Str,B,C)];
replace([A|Str],B,C) -> [A|replace(Str,B,C)].


rehash() ->
    gen_server:cast(?MODULE,rehash).

set(Mod,Key,Val) ->
    gen_server:cast(?MODULE,{set,Mod,Key,Val}).

%set_config(File) ->
    %gen_server:cast(?MODULE,{set_config,File}).

%has_config() ->
    %gen_server:call(?MODULE,has_config).

%get_config() ->
    %gen_server:call(?MODULE,get_config).

readfile(File) ->
    readfile(File,[]).

readfile(File,Acc) ->
    case file:read_line(File) of
        {ok,Line} -> readfile(File,[Line|Acc]);
        eof -> Acc;
        Error -> Error
    end.


get_all() ->
    gen_server:call(?MODULE,get).

% Returns 
%   * the first value of option X in application Y, if multiple such values exist
%   * the value of option X in application Y, if it exists
%   * undefined otherwise
%  The values are fetched primarily from the config file specified when starting the options server
%  using the app file of Y as a fallback.
get(Mod,Key) ->
    gen_server:call(?MODULE,{get,Mod,Key}).

% Like mget, but without any filtering of return types.
mget(Y,X) ->
    gen_server:call(?MODULE,{mget,Y,X}).


%handle_call(has_config,_From,none) ->
%    {reply,false,none};
%
%handle_call(has_config,_From,State) ->
%    {reply,true,State};
%
%
%handle_call(get_config,_From,none) ->
%    {reply,none,none};
%
%handle_call(get_config,_From,State={N,_}) ->
%    {reply,N,State};

handle_call(get,_From,State) ->
    {reply,State,State};

handle_call({get,Mod,Key},_From,State=#state{config_options=Options,set_options=SetOptions}) ->
    ?DEBL({options,9},"Searching for ~w",[Key]),
    GetSysOpt=fun() ->
            case application:get_env(Mod,Key) of
                undefined ->
                    application:get_key(Mod,Key);
                Ret ->
                    Ret
            end
    end,
    Value=case gb_trees:lookup(Mod,SetOptions) of
        {value,SetTree} ->
            case gb_trees:lookup(Key,SetTree) of
                {value,{string,V}} -> 
                    ?DEBL({options,9},"Found name: ~w",[V]),
                    {ok,V};
                {value,{list,V}} ->
                    ?DEBL({options,9},"Found list: ~w, returning first entry",[V]),
                    {ok,hd(V)};
                none ->
                    case gb_trees:lookup(Mod,Options) of
                        {value,OptionsTree} ->
                            case gb_trees:lookup(Key,OptionsTree) of
                                {value,{string,V}} -> 
                                    ?DEBL({options,9},"Found name: ~w",[V]),
                                    {ok,V};
                                {value,{list,V}} ->
                                    ?DEBL({options,9},"Found list: ~w, returning first entry",[V]),
                                    {ok,hd(V)};
                                none -> 
                                    GetSysOpt()
                            end;
                        none ->
                            GetSysOpt()
                    end
            end;
        none ->
            GetSysOpt()
    end,
    {reply,Value,State};


% XXX FIXME
handle_call({mget,Y,X},_From,State={_N,Names}) ->
    ?DEBL({options,9},"Searching for ~w",[X]),
    Value=case gb_trees:lookup(X,Names) of
        {value,V} -> 
            ?DEBL({options,9},"Found ~w",[V]),
            V;
        _ -> ?DEBL({options,9},"No name in ~w, returning application:get_env(~w,~w)",[N,Y,X]),
            application:get_env(Y,X)
    end,
    {reply,Value,State}.

%handle_cast({set_config,File},State) ->
    %FixedFile=fix_home(File),
    %?DEBL({options,3},"Replacing config file with file ~s",[FixedFile]),
    %{noreply,{FixedFile,rehash_(FixedFile)}};

handle_cast({set,Mod,Key,Val},State=#state{set_options=OldSets}) ->
    NewSets=case gb_trees:lookup(Mod,OldSets) of
        {value,Tree} ->
            gb_trees:enter(Mod,gb_trees:enter(Key,{string,Val},Tree),OldSets);
        none ->
            gb_trees:insert(Mod,gb_trees:insert(Key,{string,Val},gb_trees:empty()),OldSets)
    end,
    {noreply,State#state{set_options=NewSets}};


handle_cast(rehash,State=#state{config_files=Configs}) ->
    Options=lists:foldr(fun(Config,Tree) -> rehash_(Config,Tree) end,gb_trees:empty(),Configs),
    {noreply,State#state{config_options=Options}}.

terminate(_,_) ->
    ok.
    
code_change(_OldVsn, State, _Extra) ->
        {ok, State}.

handle_info(_Info, State) ->
        {noreply, State}.

