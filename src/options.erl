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
-compile({parse_transform,cut}).
-behaviour(gen_server).
-behaviour(application).


%%% TODO: 
%%% ☐ Document this module
%%% ☐ Load in options from a file as binaries rather than strings
%%%

-record(state,{
        config_files=[]::string(),
        config_options=gb_trees:empty()::gb_trees:gb_tree(_,_),
        set_options=gb_trees:empty()::gb_trees:gb_tree(_,_),
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
    %XXX This is heavily unneccessary. Remove?
    get_state/0
    ,parse_line/2
    ]).

% Official        
-export([get/2
        ,get/3
        ,get_all/0
        ,get_all/1
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
       append_config/1,
       append_configs/1,
       append_config/2,
       append_configs/2,
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
    {Options,Pairings}=lists:foldr(fun(Config,Tree) -> rehash_(Config,Tree) end,{gb_trees:empty(),[]},CN),
    {ok,#state{config_files=CN,config_options=Options,module_syms=Pairings}}.


fix_home([$~,$/|Name]) ->
    [os:getenv("HOME"),"/",Name];

fix_home(A) -> A.

append_config(Config) ->
    gen_server:cast(?MODULE,{append_config,[Config],list}).

append_configs(Configs) ->
    gen_server:cast(?MODULE,{append_config,Configs,list}).

append_config(Config,OptType) ->
    gen_server:cast(?MODULE,{append_config,[Config],OptType}).

append_configs(Configs,OptType) ->
    gen_server:cast(?MODULE,{append_config,Configs,OptType}).

rehash_({ConfigName,Type},{TreeAcc,PairingsAcc}) ->
    %try 
        case file:open(ConfigName,[read,raw]) of
            {ok,ConfigFile} ->
                % Read options from config file
                Options=readfile(ConfigFile),
                file:close(ConfigFile),
                ?DEBL({options,9},"Options: ~n ~p",[Options]),
                {MaybeParsedOpts,_}=lists:mapfoldr(fun(X,Module)-> parse_line(X,Module) end,[],Options),
                ?DEBL({options,9},"MaybeParsed: ~n ~p",[MaybeParsedOpts]),
                ParsedOpts0=lists:flatten(MaybeParsedOpts), %XXX Does this ever DO anything?
                MakeType=fun
                  ({A,B,L})-> 
                    case Type of
                      list -> {A,B,lists:flatten(L)};
                      binary -> {A,B,list_to_binary(lists:flatten(L))} 
                    end
                end,
                ParsedOpts=lists:map(MakeType,ParsedOpts0),
                ?DEBL({options,9},"Parsed: ~n ~p",[ParsedOpts]),
                ParsedTree=make_tree(ParsedOpts,TreeAcc),
                Modules=lst_ext:uniq(lists:map(fun vol_misc:fst/1,ParsedOpts)),
                NewPairings= lists:foldr(
                    fun(Module,Acc) ->
                            case application:get_key(Module,modules) of
                                undefined ->
                                    Acc;
                                {ok,ListOfChildren} ->
                                    lists:foldr(
                                        fun(Child,Bcc) ->
                                                [{Child,Module}|Bcc]
                                        end,
                                        Acc,
                                        ListOfChildren)
                            end
                    end,
                    [],
                    Modules),
                ?DEBL(9,"Module pairings: ~p",[NewPairings]),
                Pairings=lst_ext:uminsert(NewPairings,PairingsAcc),
                {ParsedTree,Pairings};
            Error ->
                ?DEBL({err,1},"Options file could not be read! Options only taken from environment file (~s ~w)",[lists:flatten(ConfigName),Error]),
                {TreeAcc,PairingsAcc}
        end
    %catch
        %_L:_E ->
            %?DEBL({err,1},"Error while parsing file! Options only taken from environment file (~s ~w ~w)",[lists:flatten(ConfigName),_L,_E]),
            %{TreeAcc,PairingsAcc}
    %end.
    .

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
    {[Last],Elddim}=lists:split(1,lists:reverse(tl(StrippedLine))),
    Middle=lists:reverse(Elddim),
    case {First,Middle,Last} of
        {$[,NewMod,$]} ->
            ?DEBL(3,"parsing app/module header",[]),
            {[],list_to_atom(NewMod)};
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
                    ?DEBL(5,"got line with colon",[]),
                    A={Mod,list_to_atom(replace(Head,$ ,$_)),fix_home(string:strip(string:join(Tail,":")))},
                    ?DEBL({options,4},"parsed colon line as ~p",[A]),
                    {A,Mod}
            end
    end.

-spec mget_m_k_v(module(),any(),gb_trees:tree(_,_)) -> false | {ok,{string,any()}|{list,[any()]}}.
mget_m_k_v(Mod,Key,ModTree) ->
    case gb_trees:lookup(Mod,ModTree) of
        {value,KeyTree} ->
            case gb_trees:lookup(Key,KeyTree) of
                {value,V} ->
                    {ok,V};
                none -> 
                    false 
            end;
        none ->
            false
    end.

-spec get_m_k_v(module(),any(),gb_trees:tree(_,_)) -> false | {ok,any()}.
get_m_k_v(Mod,Key,ModTree) ->
    case gb_trees:lookup(Mod,ModTree) of
        {value,KeyTree} ->
            case gb_trees:lookup(Key,KeyTree) of
                {value,{string,V}} -> 
                    {ok,V};
                {value,{list,V}} ->
                    {ok,hd(V)};
                none -> 
                    false 
            end;
        none ->
            false
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


get_state() ->
    gen_server:call(?MODULE,get_state).

get_all() ->
    {FileOptsTree,SetOptsTree}=gen_server:call(?MODULE,get_options),
    GeneralOpts=tree_to_list([],FileOptsTree),
    SetOpts=tree_to_list([],SetOptsTree),
    MergedOpts=lst_ext:keyumerge(1,lists:keysort(1,SetOpts),lists:keysort(1,GeneralOpts)),
    lists:map(fun get_first/1,MergedOpts).

%TODO: Bindings: check if the module is bound to an app name. If it is, app settings supercede general settings. Module settings supercede both general settings and app settings.
% ☐ is_bound(Mod) -> false|App
% ☐  set makes module bindings
% ☐  rehash also makes module bindings
% 

get_all(Module) ->
    {FileOptsTree,SetOptsTree}=gen_server:call(?MODULE,get_options),
    GeneralOpts=tree_to_list([],FileOptsTree),
    SetOpts=tree_to_list([],SetOptsTree),
    ModuleGeneralOpts=tree_to_list(Module,FileOptsTree),
    ModuleSetOpts=tree_to_list(Module,SetOptsTree),
    Generals=lst_ext:keyumerge(1,lists:keysort(1,SetOpts),lists:keysort(1,GeneralOpts)),
    Specifics=lst_ext:keyumerge(1,lists:keysort(1,ModuleSetOpts),lists:keysort(1,ModuleGeneralOpts)),
    MergedOpts=lst_ext:keyumerge(1,Specifics,Generals),
    lists:map(fun get_first/1,MergedOpts).

get_first({K,{string,A}}) -> {K,A};
get_first({K,{list,A}}) -> {K,hd(A)}.

%
%umerge_vals(A,B) ->
%    umerge_vals(A,B,[]).
%
%umerge_vals([],[],Acc) ->
%    Acc;
%
%umerge_vals(L1,[],Acc) ->
%    L1++Acc;
%
%umerge_vals([],L2,Acc) ->
%    L2++Acc;
%
%umerge_vals(LL1=[I1={A,_}|L1],LL2=[I2={B,_}|L2],Acc) ->
%    if A == B ->
%            umerge_vals(L1,L2,[I1|Acc]);
%        A < B ->
%            umerge_vals(L1,LL2,[I1|Acc]);
%        A > B ->
%            umerge_vals(LL1,L2,[I2|Acc])
%    end.



tree_to_list(OptsName,Tree) ->
    case gb_trees:lookup(OptsName,Tree) of
        {value,Opts} ->
            gb_trees:to_list(Opts);
        none ->
            []
    end.



% Returns 
%   * the first value of option X in application Y, if multiple such values exist
%   * the value of option X in application Y, if it exists
%   * undefined otherwise
%  The values are fetched primarily from the config file specified when starting the options server
%  using the app file of Y as a fallback.
get(Mod,Key) ->
    gen_server:call(?MODULE,{get,Mod,Key}).

get(Mod,Key,Default) ->
    gen_server:call(?MODULE,{get,Mod,Key,Default}).

% @spec (module(),term()) -> {ok,{string,string()}|{list,[string()]}|{env,any()}}|undefined
mget(Mod,Key) ->
    gen_server:call(?MODULE,{mget,Mod,Key}).


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

handle_call(get_state,_From,State) ->
    {reply,State,State};

handle_call(get_options,_From,State) ->
    {reply,{State#state.config_options,State#state.set_options},State};

handle_call({get,Module,Key},_From,State=#state{config_options=Options,set_options=SetOptions,module_syms=Syms}) ->
    ?DEBL({options,9},"Searching for ~w",[Key]),
    GetSysOpt=
               fun
        ([]) -> false;
        (Mod) ->
            case application:get_env(Mod,Key) of
                undefined ->
                    case application:get_key(Mod,Key) of
                        undefined ->
                            false;
                        Ret ->
                            Ret
                    end;
                Ret ->
                    Ret
            end

    end,
    ModCandidates =case lists:keyfind(Module,1,Syms) of
        {A,B} when A == B ->
            [Module,[]];
        {_Mod,ParentMod} ->
            [Module,ParentMod,[]];
        false  ->
            [Module,[]]
    end,
    Value=case get_m_k_v(Module,Key,SetOptions) of
        false ->
            lists:foldl(
                fun
                    (ModName,false) ->
                        case get_m_k_v(ModName,Key,Options) of
                            false ->
                                GetSysOpt(ModName);
                            Val ->
                                Val
                        end;
                    (_,Stuff) ->
                        Stuff
                end,
                false,
                ModCandidates);
        Val ->
            Val
    end,
    {reply,false_to_undef(Value),State};

handle_call({get,Module,Key,Default},_From,State=#state{config_options=Options,set_options=SetOptions,module_syms=Syms}) ->
    ?DEBL({options,9},"Searching for ~w",[Key]),
    GetSysOpt=
               fun
        ([]) -> false;
        (Mod) ->
            case application:get_env(Mod,Key) of
                undefined ->
                    case application:get_key(Mod,Key) of
                        undefined ->
                            false;
                        Ret ->
                            Ret
                    end;
                Ret ->
                    Ret
            end

    end,
    ModCandidates =case lists:keyfind(Module,1,Syms) of
        {A,B} when A == B ->
            [Module,[]];
        {_Mod,ParentMod} ->
            [Module,ParentMod,[]];
        false  ->
            [Module,[]]
    end,
    Value=case get_m_k_v(Module,Key,SetOptions) of
        false ->
            lists:foldl(
                fun
                    (ModName,false) ->
                        case get_m_k_v(ModName,Key,Options) of
                            false ->
                                GetSysOpt(ModName);
                            Val ->
                                Val
                        end;
                    (_,Stuff) ->
                        Stuff
                end,
                false,
                ModCandidates);
        Val ->
            Val
    end,
    {ok,ReturnValue} = case Value of
        false -> {ok,Default};
        X -> X
    end,
    {reply,ReturnValue,State};


% XXX FIXME
handle_call({mget,Module,Key},_From,State=#state{config_options=Options,set_options=SetOptions,module_syms=Syms}) ->
    ?DEBL({options,9},"Searching for ~w",[Key]),
    GetSysOpt=
               fun
        ([]) -> false;
        (Mod) ->
            case application:get_env(Mod,Key) of
                undefined ->
                    case application:get_key(Mod,Key) of
                        undefined ->
                            false;
                        Ret ->
                            Ret
                    end;
                Ret ->
                    Ret
            end

    end,
    ModCandidates =case lists:keyfind(Module,1,Syms) of
        {A,B} when A == B ->
            [Module,[]];
        {_Mod,ParentMod} ->
            [Module,ParentMod,[]];
        false  ->
            [Module,[]]
    end,
    Value=case mget_m_k_v(Module,Key,SetOptions) of
        false ->
            lists:foldl(
                fun
                    (ModName,false) ->
                        case mget_m_k_v(ModName,Key,Options) of
                            false ->
                                GetSysOpt(ModName);
                            Val ->
                                Val
                        end;
                    (_,Stuff) ->
                        Stuff
                end,
                false,
                ModCandidates);
        Val ->
            Val
    end,
    {reply,false_to_undef(Value),State}.

handle_cast({append_config,ConfigNames,Type},State=#state{config_files=OldCN}) ->
    NewCN0=lists:map(fix_home(_),ConfigNames),
    NewCN=lists:map({_,Type},NewCN0),
    % Append new files, in order, to the end of the list, unless they already exist - in which case they will keep their place in the list (for now).
    CN=lst_ext:ruminsert(NewCN,OldCN), % XXX This will break if a config name has multiple types!
    {Options,Pairings}=lists:foldr(fun(Config,Tree) -> rehash_(Config,Tree) end,{gb_trees:empty(),[]},CN),
    {noreply,State#state{config_files=CN,config_options=Options,module_syms=Pairings}};

handle_cast({set,Mod,Key,Val},State=#state{set_options=OldSets}) ->
    NewSets=case gb_trees:lookup(Mod,OldSets) of
        {value,Tree} ->
            gb_trees:enter(Mod,gb_trees:enter(Key,{string,Val},Tree),OldSets);
        none ->
            gb_trees:insert(Mod,gb_trees:insert(Key,{string,Val},gb_trees:empty()),OldSets)
    end,
    {noreply,State#state{set_options=NewSets}};


handle_cast(rehash,State=#state{config_files=Configs}) ->
    ?DEBL(6,"rehashing...",[]),
    {Options,Pairings}=lists:foldr(fun(Config,Tree) -> rehash_(Config,Tree) end,{gb_trees:empty(),[]},Configs),
    ?DEBL(6,"...done",[]),
    {noreply,State#state{config_options=Options,module_syms=Pairings}}.

false_to_undef(false) -> undefined;
false_to_undef(X) -> X.

terminate(_,_) ->
    ok.
    
code_change(_OldVsn, State, _Extra) ->
        {ok, State}.

handle_info(_Info, State) ->
        {noreply, State}.

