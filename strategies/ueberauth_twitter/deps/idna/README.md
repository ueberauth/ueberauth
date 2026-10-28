## erlang-idna

A pure Erlang IDNA implementation that folllow the [RFC5891](https://tools.ietf.org/html/rfc5891).

* support IDNA 2008 and IDNA 2003.
* label validation:
    - [x] **check NFC**: Label must be in Normalization Form C
    - [x] **check hyphen**: The Unicode string MUST NOT contain "--" (two consecutive hyphens) in
    the third and fourth character positions and MUST NOT start or end
    with a "-" (hyphen).
    - [x]  **Leading Combining Marks**: The Unicode string MUST NOT begin with a combining mark or combining character (see The Unicode Standard, Section 2.11 [Unicode](https://tools.ietf.org/html/rfc5891#ref-Unicode) for an  exact definition).
    - [x] **Contextual Rules**: The Unicode string MUST NOT contain any characters whose validity is
    context-dependent, unless the validity is positively confirmed by a contextual rule.  To check this, each code point identified as  CONTEXTJ or CONTEXTO in the Tables document [RFC5892](https://tools.ietf.org/html/rfc5892#section-2.7) MUST have a  non-null rule.  If such a code point is missing a rule, the label is  invalid.  If the rule exists but the result of applying the rule is  negative or inconclusive, the proposed label is invalid.
    - [x] **check BIDI**: label contains any characters from scripts that are
    written from right to left, it MUST meet the Bidi criteria  [rfc5893](https://tools.ietf.org/html/rfc5893)




## Usage



`idna:encode/{1,2}` and `idna:decode/{1, 2}` functions are used to encode or decode an Internationalized Domain
Names using IDNA protocol.

Input can be mapped to unicode using [uts46](https://unicode.org/reports/tr46/#Introduction)
by setting  the `uts46` flag to true (default is false). If transition from IDNA 2003 to
IDNA 2008 is needed, the flag `transitional` can be set to `true`, (`default` is false). If
conformance to STD3 is needed, the flag `std3_rules` can be set to true. (default is `false`).

example:

```erlang
1> idna:encode("日本語。ＪＰ", [uts46]).
"xn--wgv71a119e.xn--jp-"
2> idna:encode("日本語.ＪＰ", [uts46]).
"xn--wgv71a119e.xn--jp-"
...
```


Legacy support of IDNA 2003 is also available with  `to_ascii` and `to_unicode` functions:


```erlang
1> Domain = "www.詹姆斯.com".
[119,119,119,46,35449,22982,26031,46,99,111,109]
2> Encoded =  idna:to_ascii("www.詹姆斯.com").
"www.xn--8ws00zhy3a.com"
3> idna:to_unicode(Encoded).
[119,119,119,46,35449,22982,26031,46,99,111,109]
```



Update Unicode data

wget -O test/IdnaTestV2.txt https://www.unicode.org/Public/idna/latest/IdnaTestV2.txt
wget -O uc_spec/ArabicShaping.txt https://www.unicode.org/Public/UNIDATA/ArabicShaping.txt
wget -O uc_spec/IdnaMappingTable.txt https://www.unicode.org/Public/idna/latest/IdnaMappingTable.txt
wget -O uc_spec/Scripts.txt https://www.unicode.org/Public/UNIDATA/Scripts.txt
wget -O uc_spec/UnicodeData.txt https://www.unicode.org/Public/UNIDATA/UnicodeData.txt

git clone https://github.com/kjd/idna.git
./idna/tools/idna-data make-table --version 13.0.0 > uc_spec/idna-table.txt

cd uc_spec
./gen_idnadata_mod.escript
./gen_idna_table_mod.escript
./gen_idna_mapping_mod.escript
