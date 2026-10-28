?METHOD_TPL(delete).
?METHOD_TPL(get).
?METHOD_TPL(head).
?METHOD_TPL(post).
?METHOD_TPL(put).

%% hackney:connect/1 already exists.
%% ?METHOD_TPL(connect).
?METHOD_TPL(options).
?METHOD_TPL(trace).

%% WEBDAV
?METHOD_TPL(copy).
?METHOD_TPL(lock).
?METHOD_TPL(mkcol).
?METHOD_TPL(move).
?METHOD_TPL(propfind).
?METHOD_TPL(proppatch).
?METHOD_TPL(search).
?METHOD_TPL(unlock).

%% SUBVERSION
?METHOD_TPL(report).
?METHOD_TPL(mkactivity).
?METHOD_TPL(checkout).
?METHOD_TPL(merge).

%% UPNP
?METHOD_TPL(msearch).
?METHOD_TPL(notify).
?METHOD_TPL(subscribe).
?METHOD_TPL(unsubscribe).

%% RFC-5789
?METHOD_TPL(patch).
?METHOD_TPL(purge).

-undef(METHOD_TPL).
