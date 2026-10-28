%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%

%% @private
-module(hackney_ssl_certificate).

-include_lib("public_key/include/OTP-PUB-KEY.hrl").

-export(
   [public_key_info/1
   ]).

-spec public_key_info(Cert) -> PKI
        when Cert :: #'OTPCertificate'{tbsCertificate :: TBSCert},
             TBSCert :: #'OTPTBSCertificate'{subjectPublicKeyInfo :: PKI}.
public_key_info(Cert) ->
  ((Cert#'OTPCertificate'.tbsCertificate)#'OTPTBSCertificate'.subjectPublicKeyInfo).
