-record(hackney_url, {
 transport        :: atom(),
 scheme           :: atom(),
 netloc   = <<>>  :: binary(),
 raw_path         :: binary() | undefined,
 path = <<>>      :: binary() | undefined | nil,
 qs = <<>>        :: binary(),
 fragment = <<>>  :: binary(),
 host = ""        :: string(),
 port             :: integer() | undefined,
 user = <<>>      :: binary(),
 password = <<>>  :: binary()
}).

-type hackney_url() :: #hackney_url{}.

-record(hparser, {
 type = auto            :: atom(),
 max_line_length = 4096 :: integer(),
 max_empty_lines = 10   :: integer(),
 empty_lines = 0        :: integer(),
 state = on_first_line  :: atom(),
 buffer = <<>>          :: binary(),
 version                :: {integer(), integer()} | undefined,
 method = <<>>          :: binary(),
 partial_headers = []   :: list(),
 clen = undefined        :: integer() | undefined | bad_int,
 te = <<>>              :: binary(),
 connection = <<>>      :: binary(),
 ctype = <<>>           :: binary(),
 location = <<>>        :: binary(),
 body_state = waiting   :: atom() | tuple()
}).
