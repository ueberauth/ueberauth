%%% -*- erlang -*-
%%%
%%% This file is part of hackney_lib released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%% Copyright (c) 2011-2012, Loïc Hoguin <essen@ninenines.eu>
%%% Copyright (c) 2012-2015 Benoît Chesneau <benoitc@e-engura.org>
%%%

-module(hackney_date).

-export([date_to_rfc2109/1]).

-export([parse_http_date/1,
  rfc2109_to_date/1,
  rfc1123_to_date/1,
  rfc850_to_date/1,
  asctime_to_date/1]).

%% @doc Return the date formatted according to RFC2109.

-spec date_to_rfc2109(calendar:datetime()) -> binary().
date_to_rfc2109({Date = {Y, Mo, D}, {H, Mi, S}}) ->
  Wday = calendar:day_of_the_week(Date),
  <<(weekday_int(Wday))/binary, ", ",
    (pad_int(D))/binary, "-",
    (month_int(Mo))/binary, "-",
    (year_int(Y))/binary, " ",
    (pad_int(H))/binary, ":",
    (pad_int(Mi))/binary, ":",
    (pad_int(S))/binary, " GMT">>.

%% @doc Parse an HTTP date (RFC1123, RFC850 or asctime date).
%% @end
%%
%% While this may not be the most efficient date parsing we can do,
%% it should work fine for our purposes because all HTTP dates should
%% be sent as RFC1123 dates in HTTP/1.1.
-spec parse_http_date(binary()) -> any().
parse_http_date(Data) ->
  case rfc1123_to_date(Data) of
    {error, badarg} ->
      case rfc850_to_date(Data) of
        {error, badarg} ->
          case asctime_to_date(Data) of
            {error, badarg} ->
              case rfc2109_to_date(Data) of
                {error, badarg} ->
                  {error, badarg};
                HTTPDate ->
                  HTTPDate
              end;
            HTTPDate ->
              HTTPDate
          end;
        HTTPDate ->
          HTTPDate
      end;
    HTTPDate ->
      HTTPDate
  end.

%% @doc Parse an RFC2109 date.
-spec rfc2109_to_date(binary()) -> any().
rfc2109_to_date(Data) ->
  wkday(Data,
    fun (<< ", ", Rest/binary >>, _WkDay) ->
      date4(Rest,
        fun (<< " ", Rest2/binary >>, Date) ->
          time(Rest2,
            fun (<< " GMT", Rest3/binary >>, Time) ->
              http_date_ret(Rest3, {Date, Time});
                (_Any, _Time) ->
                  {error, badarg}
            end);
            (_Any, _Date) ->
              {error, badarg}
        end);
        (_Any, _WkDay) ->
          {error, badarg}
    end).

%% @doc Parse an RFC1123 date.
-spec rfc1123_to_date(binary()) -> any().
rfc1123_to_date(Data) ->
  wkday(Data,
    fun (<< ", ", Rest/binary >>, _WkDay) ->
      date1(Rest,
        fun (<< " ", Rest2/binary >>, Date) ->
          time(Rest2,
            fun (<< " GMT", Rest3/binary >>, Time) ->
              http_date_ret(Rest3, {Date, Time});
                (_Any, _Time) ->
                  {error, badarg}
            end);
            (_Any, _Date) ->
              {error, badarg}
        end);
        (_Any, _WkDay) ->
          {error, badarg}
    end).

%% @doc Parse an RFC850 date.
-spec rfc850_to_date(binary()) -> any().
%% From the RFC:
%% HTTP/1.1 clients and caches SHOULD assume that an RFC-850 date
%% which appears to be more than 50 years in the future is in fact
%% in the past (this helps solve the "year 2000" problem).
rfc850_to_date(Data) ->
  weekday(Data,
    fun (<< ", ", Rest/binary >>, _WeekDay) ->
      date2(Rest,
        fun (<< " ", Rest2/binary >>, Date) ->
          time(Rest2,
            fun (<< " GMT", Rest3/binary >>, Time) ->
              http_date_ret(Rest3, {Date, Time});
                (_Any, _Time) ->
                  {error, badarg}
            end);
            (_Any, _Date) ->
              {error, badarg}
        end);
        (_Any, _WeekDay) ->
          {error, badarg}
    end).

%% @doc Parse an asctime date.
-spec asctime_to_date(binary()) -> any().
asctime_to_date(Data) ->
  wkday(Data,
    fun (<< " ", Rest/binary >>, _WkDay) ->
      date3(Rest,
        fun (<< " ", Rest2/binary >>, PartialDate) ->
          time(Rest2,
            fun (<< " ", Rest3/binary >>, Time) ->
              asctime_year(Rest3,
                PartialDate, Time);
                (_Any, _Time) ->
                  {error, badarg}
            end);
            (_Any, _PartialDate) ->
              {error, badarg}
        end);
        (_Any, _WkDay) ->
          {error, badarg}
    end).

-spec asctime_year(binary(), tuple(), tuple()) -> any().
asctime_year(<< Y1, Y2, Y3, Y4, Rest/binary >>, {Month, Day}, Time)
  when Y1 >= $0, Y1 =< $9, Y2 >= $0, Y2 =< $9,
       Y3 >= $0, Y3 =< $9, Y4 >= $0, Y4 =< $9 ->
  Year = (Y1 - $0) * 1000 + (Y2 - $0) * 100 + (Y3 - $0) * 10 + (Y4 - $0),
  http_date_ret(Rest, {{Year, Month, Day}, Time}).

-spec http_date_ret(binary(), tuple()) -> any().
http_date_ret(Data, DateTime = {Date, _Time}) ->
  hackney_bstr:whitespace(Data,
    fun (<<>>) ->
      case calendar:valid_date(Date) of
        true -> DateTime;
        false -> {error, badarg}
      end;
        (_Any) ->
          {error, badarg}
    end).

%% We never use it, pretty much just checks the wkday is right.
-spec wkday(binary(), fun()) -> any().
wkday(<< WkDay:3/binary, Rest/binary >>, Fun)
  when WkDay =:= <<"Mon">>; WkDay =:= <<"Tue">>; WkDay =:= <<"Wed">>;
       WkDay =:= <<"Thu">>; WkDay =:= <<"Fri">>; WkDay =:= <<"Sat">>;
       WkDay =:= <<"Sun">> ->
  Fun(Rest, WkDay);
wkday(_Any, _Fun) ->
  {error, badarg}.

%% We never use it, pretty much just checks the weekday is right.
-spec weekday(binary(), fun()) -> any().
weekday(<< "Monday", Rest/binary >>, Fun) ->
  Fun(Rest, <<"Monday">>);
weekday(<< "Tuesday", Rest/binary >>, Fun) ->
  Fun(Rest, <<"Tuesday">>);
weekday(<< "Wednesday", Rest/binary >>, Fun) ->
  Fun(Rest, <<"Wednesday">>);
weekday(<< "Thursday", Rest/binary >>, Fun) ->
  Fun(Rest, <<"Thursday">>);
weekday(<< "Friday", Rest/binary >>, Fun) ->
  Fun(Rest, <<"Friday">>);
weekday(<< "Saturday", Rest/binary >>, Fun) ->
  Fun(Rest, <<"Saturday">>);
weekday(<< "Sunday", Rest/binary >>, Fun) ->
  Fun(Rest, <<"Sunday">>);
weekday(_Any, _Fun) ->
  {error, badarg}.

-spec date1(binary(), fun()) -> any().
date1(<< D1, D2, " ", M:3/binary, " ", Y1, Y2, Y3, Y4, Rest/binary >>, Fun)
  when D1 >= $0, D1 =< $9, D2 >= $0, D2 =< $9,
       Y1 >= $0, Y1 =< $9, Y2 >= $0, Y2 =< $9,
       Y3 >= $0, Y3 =< $9, Y4 >= $0, Y4 =< $9 ->
  case month_to_int(M) of
    {error, badarg} ->
      {error, badarg};
    Month ->
      Fun(Rest, {
        (Y1 - $0) * 1000 + (Y2 - $0) * 100 + (Y3 - $0) * 10 + (Y4 - $0),
        Month,
        (D1 - $0) * 10 + (D2 - $0)
      })
  end;
date1(_Data, _Fun) ->
  {error, badarg}.

-spec date2(binary(), fun()) -> any().
date2(<< D1, D2, "-", M:3/binary, "-", Y1, Y2, Rest/binary >>, Fun)
  when D1 >= $0, D1 =< $9, D2 >= $0, D2 =< $9,
       Y1 >= $0, Y1 =< $9, Y2 >= $0, Y2 =< $9 ->
  case month_to_int(M) of
    {error, badarg} ->
      {error, badarg};
    Month ->
      Year = (Y1 - $0) * 10 + (Y2 - $0),
      Year2 = case Year > 50 of
                true -> Year + 1900;
                false -> Year + 2000
              end,
      Fun(Rest, {
        Year2,
        Month,
        (D1 - $0) * 10 + (D2 - $0)
      })
  end;
date2(_Data, _Fun) ->
  {error, badarg}.

-spec date3(binary(), fun()) -> any().
date3(<< M:3/binary, " ", D1, D2, Rest/binary >>, Fun)
  when (D1 >= $0 andalso D1 =< $3) orelse D1 =:= $\s,
       D2 >= $0, D2 =< $9 ->
  case month_to_int(M) of
    {error, badarg} ->
      {error, badarg};
    Month ->
      Day = case D1 of
              $\s -> D2 - $0;
              D1 -> (D1 - $0) * 10 + (D2 - $0)
            end,
      Fun(Rest, {Month, Day})
  end;
date3(_Data, _Fun) ->
  {error, badarg}.


date4(<< D1, D2, "-", M:3/binary, "-", Y1, Y2, Y3, Y4, Rest/binary >>, Fun)
  when D1 >= $0, D1 =< $9, D2 >= $0, D2 =< $9,
       Y1 >= $0, Y1 =< $9, Y2 >= $0, Y2 =< $9,
       Y3 >= $0, Y3 =< $9, Y4 >= $0, Y4 =< $9 ->
  case month_to_int(M) of
    {error, badarg} ->
      {error, badarg};
    Month ->
      Fun(Rest, {
        (Y1 - $0) * 1000 + (Y2 - $0) * 100 + (Y3 - $0) * 10 + (Y4 - $0),
        Month,
        (D1 - $0) * 10 + (D2 - $0)
      })
  end;
date4(_Data, _Fun) ->
  {error, badarg}.

-spec month_to_int(<< _:24 >>) -> 1..12 | {error, badarg}.
month_to_int(<<"Jan">>) -> 1;
month_to_int(<<"Feb">>) -> 2;
month_to_int(<<"Mar">>) -> 3;
month_to_int(<<"Apr">>) -> 4;
month_to_int(<<"May">>) -> 5;
month_to_int(<<"Jun">>) -> 6;
month_to_int(<<"Jul">>) -> 7;
month_to_int(<<"Aug">>) -> 8;
month_to_int(<<"Sep">>) -> 9;
month_to_int(<<"Oct">>) -> 10;
month_to_int(<<"Nov">>) -> 11;
month_to_int(<<"Dec">>) -> 12;
month_to_int(_Any) -> {error, badarg}.



-spec time(binary(), fun()) -> any().
time(<< H1, H2, ":", M1, M2, ":", S1, S2, Rest/binary >>, Fun)
  when H1 >= $0, H1 =< $2, H2 >= $0, H2 =< $9,
       M1 >= $0, M1 =< $5, M2 >= $0, M2 =< $9,
       S1 >= $0, S1 =< $5, S2 >= $0, S2 =< $9 ->
  Hour = (H1 - $0) * 10 + (H2 - $0),
  case Hour < 24 of
    true ->
      Time = {
        Hour,
        (M1 - $0) * 10 + (M2 - $0),
        (S1 - $0) * 10 + (S2 - $0)
      },
      Fun(Rest, Time);
    false ->
      {error, badarg}
  end.



-spec pad_int(0..59) -> <<_:16>>.
pad_int( 0) -> <<"00">>;
pad_int( 1) -> <<"01">>;
pad_int( 2) -> <<"02">>;
pad_int( 3) -> <<"03">>;
pad_int( 4) -> <<"04">>;
pad_int( 5) -> <<"05">>;
pad_int( 6) -> <<"06">>;
pad_int( 7) -> <<"07">>;
pad_int( 8) -> <<"08">>;
pad_int( 9) -> <<"09">>;
pad_int(10) -> <<"10">>;
pad_int(11) -> <<"11">>;
pad_int(12) -> <<"12">>;
pad_int(13) -> <<"13">>;
pad_int(14) -> <<"14">>;
pad_int(15) -> <<"15">>;
pad_int(16) -> <<"16">>;
pad_int(17) -> <<"17">>;
pad_int(18) -> <<"18">>;
pad_int(19) -> <<"19">>;
pad_int(20) -> <<"20">>;
pad_int(21) -> <<"21">>;
pad_int(22) -> <<"22">>;
pad_int(23) -> <<"23">>;
pad_int(24) -> <<"24">>;
pad_int(25) -> <<"25">>;
pad_int(26) -> <<"26">>;
pad_int(27) -> <<"27">>;
pad_int(28) -> <<"28">>;
pad_int(29) -> <<"29">>;
pad_int(30) -> <<"30">>;
pad_int(31) -> <<"31">>;
pad_int(32) -> <<"32">>;
pad_int(33) -> <<"33">>;
pad_int(34) -> <<"34">>;
pad_int(35) -> <<"35">>;
pad_int(36) -> <<"36">>;
pad_int(37) -> <<"37">>;
pad_int(38) -> <<"38">>;
pad_int(39) -> <<"39">>;
pad_int(40) -> <<"40">>;
pad_int(41) -> <<"41">>;
pad_int(42) -> <<"42">>;
pad_int(43) -> <<"43">>;
pad_int(44) -> <<"44">>;
pad_int(45) -> <<"45">>;
pad_int(46) -> <<"46">>;
pad_int(47) -> <<"47">>;
pad_int(48) -> <<"48">>;
pad_int(49) -> <<"49">>;
pad_int(50) -> <<"50">>;
pad_int(51) -> <<"51">>;
pad_int(52) -> <<"52">>;
pad_int(53) -> <<"53">>;
pad_int(54) -> <<"54">>;
pad_int(55) -> <<"55">>;
pad_int(56) -> <<"56">>;
pad_int(57) -> <<"57">>;
pad_int(58) -> <<"58">>;
pad_int(59) -> <<"59">>.

-spec weekday_int(1..7) -> <<_:24>>.
weekday_int(1) -> <<"Mon">>;
weekday_int(2) -> <<"Tue">>;
weekday_int(3) -> <<"Wed">>;
weekday_int(4) -> <<"Thu">>;
weekday_int(5) -> <<"Fri">>;
weekday_int(6) -> <<"Sat">>;
weekday_int(7) -> <<"Sun">>.

-spec month_int(1..12) -> <<_:24>>.
month_int( 1) -> <<"Jan">>;
month_int( 2) -> <<"Feb">>;
month_int( 3) -> <<"Mar">>;
month_int( 4) -> <<"Apr">>;
month_int( 5) -> <<"May">>;
month_int( 6) -> <<"Jun">>;
month_int( 7) -> <<"Jul">>;
month_int( 8) -> <<"Aug">>;
month_int( 9) -> <<"Sep">>;
month_int(10) -> <<"Oct">>;
month_int(11) -> <<"Nov">>;
month_int(12) -> <<"Dec">>.

-spec year_int(pos_integer()) -> <<_:32>>.
year_int(1970) -> <<"1970">>;
year_int(1971) -> <<"1971">>;
year_int(1972) -> <<"1972">>;
year_int(1973) -> <<"1973">>;
year_int(1974) -> <<"1974">>;
year_int(1975) -> <<"1975">>;
year_int(1976) -> <<"1976">>;
year_int(1977) -> <<"1977">>;
year_int(1978) -> <<"1978">>;
year_int(1979) -> <<"1979">>;
year_int(1980) -> <<"1980">>;
year_int(1981) -> <<"1981">>;
year_int(1982) -> <<"1982">>;
year_int(1983) -> <<"1983">>;
year_int(1984) -> <<"1984">>;
year_int(1985) -> <<"1985">>;
year_int(1986) -> <<"1986">>;
year_int(1987) -> <<"1987">>;
year_int(1988) -> <<"1988">>;
year_int(1989) -> <<"1989">>;
year_int(1990) -> <<"1990">>;
year_int(1991) -> <<"1991">>;
year_int(1992) -> <<"1992">>;
year_int(1993) -> <<"1993">>;
year_int(1994) -> <<"1994">>;
year_int(1995) -> <<"1995">>;
year_int(1996) -> <<"1996">>;
year_int(1997) -> <<"1997">>;
year_int(1998) -> <<"1998">>;
year_int(1999) -> <<"1999">>;
year_int(2000) -> <<"2000">>;
year_int(2001) -> <<"2001">>;
year_int(2002) -> <<"2002">>;
year_int(2003) -> <<"2003">>;
year_int(2004) -> <<"2004">>;
year_int(2005) -> <<"2005">>;
year_int(2006) -> <<"2006">>;
year_int(2007) -> <<"2007">>;
year_int(2008) -> <<"2008">>;
year_int(2009) -> <<"2009">>;
year_int(2010) -> <<"2010">>;
year_int(2011) -> <<"2011">>;
year_int(2012) -> <<"2012">>;
year_int(2013) -> <<"2013">>;
year_int(2014) -> <<"2014">>;
year_int(2015) -> <<"2015">>;
year_int(2016) -> <<"2016">>;
year_int(2017) -> <<"2017">>;
year_int(2018) -> <<"2018">>;
year_int(2019) -> <<"2019">>;
year_int(2020) -> <<"2020">>;
year_int(2021) -> <<"2021">>;
year_int(2022) -> <<"2022">>;
year_int(2023) -> <<"2023">>;
year_int(2024) -> <<"2024">>;
year_int(2025) -> <<"2025">>;
year_int(2026) -> <<"2026">>;
year_int(2027) -> <<"2027">>;
year_int(2028) -> <<"2028">>;
year_int(2029) -> <<"2029">>;
year_int(Year) -> list_to_binary(integer_to_list(Year)).
