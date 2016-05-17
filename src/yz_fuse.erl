%% -------------------------------------------------------------------
%% Copyright (c) 2015 Basho Technologies, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(yz_fuse).
-include("yokozuna.hrl").

%% setup
-export([setup/0]).

%% api
-export([create/1, check/1, check_all_fuses_not_blown/1, melt/1, remove/1, reset/1]).

%% helpers
-export([fuse_context/0]).

%% used only by tests
-export([fuse_name_for_index/1, index_for_fuse_name/1]).

%% stats helpers
-export([aggregate_index_stats/3, stats/0, get_stats_for_index/1, print_stats_for_index/1]).

%% types
-export_type([fuse_check/0, fuse_namespace/0, fuse_name/0,
              encoded_fuse_name/0]).

-define(DYNAMIC_STATS, [fuse_recovered, fuse_blown]).

-type fuse_check() :: ok | blown | melt.
-type application_name() :: atom().
-type fuse_namespace() :: atom().
-type fuse_name() :: binary().
-type encoded_fuse_name() :: atom().

%%%===================================================================
%%% Setup
%%%===================================================================

%% @doc Setup Fuse stats
-spec setup() -> ok.
setup() ->
    ok = fuse_event:add_handler(yz_events, []),

    %% Set up fuse stats
    application:set_env(fuse, stats_plugin, fuse_stats_exometer).

%%%===================================================================
%%% API
%%%===================================================================

-spec create(index_name()) -> ok.
create(Index) ->
    FuseName = fuse_name_for_index(Index),
    case check(FuseName) of
        {error, not_found} ->
            ?INFO("Creating fuse for search index ~s", [Index]),
            MaxR = app_helper:get_env(?YZ_APP_NAME, ?ERR_THRESH_FAIL_COUNT,
                                      3),
            MaxT = app_helper:get_env(?YZ_APP_NAME,
                                      ?ERR_THRESH_FAIL_INTERVAL,
                                      5000),
            Refresh = {reset,
                       app_helper:get_env(?YZ_APP_NAME,
                                          ?ERR_THRESH_RESET_INTERVAL,
                                          30000)},
            Strategy = {standard, MaxR, MaxT},
            Opts = {Strategy, Refresh},
            fuse:install(FuseName, Opts),
            yz_stat:create_dynamic_stats(Index, ?DYNAMIC_STATS),
            ok;
        _ -> ok
end.

-spec remove(index_name()) -> ok.
remove(Index) ->
    FuseName = fuse_name_for_index(Index),
    fuse:remove(FuseName),
    yz_stat:delete_dynamic_stats(Index, ?DYNAMIC_STATS),
    ok.

-spec reset(index_name()) -> ok.
reset(Index) ->
    fuse:reset(fuse_name_for_index(Index)),
    ok.

-spec check(index_name()|atom()) -> ok | blown | {error, not_found}.
check(Index) when is_binary(Index) ->
    check(fuse_name_for_index(Index));
check(Index) ->
    fuse:ask(Index, fuse_context()).

-spec check_all_fuses_not_blown([index_name()]) -> boolean().
check_all_fuses_not_blown(Indexes) ->
    lists:all(fun(I) -> blown =/= check(I) end, Indexes).

-spec melt(index_name()) -> ok.
melt(Index) ->
    fuse:melt(fuse_name_for_index(Index)).

%%%===================================================================
%%% Helpers
%%%===================================================================

-spec fuse_context() -> async_dirty | sync.
fuse_context() ->
    app_helper:get_env(?YZ_APP_NAME, ?FUSE_CTX, async_dirty).

%% @doc Returns the encoded name for a fuse given a `Namespace' and a `Name'.
%% The `Namespace' provides identifying context for the fuse (similar to a
%% bucket in Riak) and must be an atom, such as yz_index for example. 
-spec encode_fuse_name(Namespace::atom(), Name::binary()) -> encoded_fuse_name().
encode_fuse_name(Namespace, Name) ->
    Fuse = {fuse, Namespace, Name},
    Base64 = base64:encode(term_to_binary(Fuse)),
    binary_to_atom(Base64, latin1).

%% @doc Given an atom generated by the encode_fuse_name/2 function, decodes it
%% into a tuple of the form {fuse, Namespace, Name}, where Namespace and Name
%% are the arguments to encode_fuse_name.
-spec decode_fuse_name(encoded_fuse_name())
                      -> {fuse, Namespace::fuse_namespace(), Name::fuse_name()}.
decode_fuse_name(Name) ->
    Fuse = base64:decode(atom_to_binary(Name, latin1)),
    {fuse, _Namespace, _Name} = binary_to_term(Fuse).

%% @doc Returns the encoded name for a fuse based on the given `Index'.
-spec fuse_name_for_index(Index::index_name()) -> encoded_fuse_name().
fuse_name_for_index(Index) ->
    encode_fuse_name(yz_index, Index).

%% @doc Given an encoded fuse name generated by the fuse_name_for_index/1
%% function, returns the index name that was used to generate it.
-spec index_for_fuse_name(encoded_fuse_name()) -> index_name().
index_for_fuse_name(Name) ->
    {fuse, yz_index, Index} = decode_fuse_name(Name),
    Index.

%%%===================================================================
%%% Stats
%%%===================================================================

stats() ->
    Spec = fun(N, M, F, As) ->
               {[N], {function, M, F, As, match, value}, [], [{value, N}]}
           end,
    [Spec(N, M, F, As) ||
        {N, M, F, As} <- [{search_index_error_threshold_ok_count, yz_fuse,
                          aggregate_index_stats, [fuse, ok, count]},
                         {search_index_error_threshold_ok_one, yz_fuse,
                          aggregate_index_stats, [fuse, ok, one]},
                         {search_index_error_threshold_failure_count, yz_fuse,
                          aggregate_index_stats, [fuse, melt, count]},
                         {search_index_error_threshold_failure_one, yz_fuse,
                          aggregate_index_stats, [fuse, melt, one]},
                         {search_index_error_threshold_blown_count, yz_fuse,
                          aggregate_index_stats, [yz_fuse, blown, count]},
                         {search_index_error_threshold_blown_one, yz_fuse,
                          aggregate_index_stats, [yz_fuse, blown, one]},
                         {search_index_error_threshold_recovered_count, yz_fuse,
                          aggregate_index_stats, [yz_fuse, recovered, count]},
                         {search_index_error_threshold_recovered_one, yz_fuse,
                          aggregate_index_stats, [yz_fuse, recovered, one]}]].

-spec aggregate_index_stats(application_name(), fuse_check(), count|one) -> non_neg_integer().
aggregate_index_stats(Application, FuseCheck, Stat) ->
    proplists:get_value(Stat,
                        exometer:aggregate([{{[Application, '_', FuseCheck],'_','_'},
                                             [], [true]}], [Stat])).

%% @doc NB.  This function is meant to be called manually from the console.
-spec print_stats_for_index(atom() | index_name()) -> ok.
print_stats_for_index(Index) when is_atom(Index) ->
    print_stats_for_index(?ATOM_TO_BIN(Index));
print_stats_for_index(Index) ->
    case get_stats_for_index(Index) of
        {error, _} ->
            io:format("No stats found for index ~s\n", [Index]);
        StatsList ->
            lists:foreach(
              fun({Check, Stats}) ->
                  io:format(
                      "Index - ~s: count: ~p | one: | ~p for fuse stat `~s`\n",
                      [Index, proplists:get_value(count, Stats),
                          proplists:get_value(one, Stats), Check])
              end,
              StatsList
            )
    end.

-spec get_stats_for_index(index_name()) -> {error, Reason::term()} | [{ok|melt|blown|recovered, term()}].
get_stats_for_index(Index) ->
    case check(Index) of
        {error, _} ->
            {error, {no_stats_for_index, Index}};
        _ ->
            FuseName = fuse_name_for_index(Index),
            lists:map(
                fun({Application, Check}) ->
                    {ok, Stats} = exometer:get_value([Application, FuseName, Check]),
                    {Check, Stats}
                end, [{fuse, ok}, {fuse, melt}, {yz_fuse, blown}, {yz_fuse, recovered}])
    end.
