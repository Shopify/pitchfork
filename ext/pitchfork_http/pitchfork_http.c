
#line 1 "pitchfork_http.rl"
/**
 * Copyright (c) 2009 Eric Wong (all bugs are Eric's fault)
 * Copyright (c) 2005 Zed A. Shaw
 * You can redistribute it and/or modify it under the same terms as Ruby 1.8 or
 * the GPLv2+ (GPLv3+ preferred)
 */
#include "ruby.h"
#include "ext_help.h"
#include <assert.h>
#include <string.h>
#include <sys/types.h>
#include "common_field_optimization.h"
#include "global_variables.h"
#include "c_util.h"
#include "epollexclusive.h"
#include "child_subreaper.h"

void init_pitchfork_httpdate(void);
void init_pitchfork_memory_page(VALUE);

#define UH_FL_CHUNKED  0x1
#define UH_FL_HASBODY  0x2
#define UH_FL_INBODY   0x4
#define UH_FL_HASTRAILER 0x8
#define UH_FL_INTRAILER 0x10
#define UH_FL_INCHUNK  0x20
#define UH_FL_REQEOF 0x40
#define UH_FL_KAVERSION 0x80
#define UH_FL_HASHEADER 0x100
#define UH_FL_TO_CLEAR 0x200
#define UH_FL_RESSTART 0x400 /* for check_client_connection */
#define UH_FL_HIJACK 0x800

/* all of these flags need to be set for keepalive to be supported */
#define UH_FL_KEEPALIVE (UH_FL_KAVERSION | UH_FL_REQEOF | UH_FL_HASHEADER)

static unsigned int MAX_HEADER_LEN = 1024 * (80 + 32); /* same as Mongrel */

/* keep this small for other servers (e.g. yahns) since every client has one */
struct http_parser {
  int cs; /* Ragel internal state */
  unsigned int flags;
  unsigned int mark;
  unsigned int offset;
  union { /* these 2 fields don't nest */
    unsigned int field;
    unsigned int query;
  } start;
  union {
    unsigned int field_len; /* only used during header processing */
    unsigned int dest_offset; /* only used during body processing */
  } s;
  VALUE buf;
  VALUE env;
  VALUE cont; /* Qfalse: unset, Qnil: ignored header, T_STRING: append */
  union {
    off_t content;
    off_t chunk;
  } len;
};

static ID id_set_backtrace, id_is_chunked_p;
static VALUE cHttpParser;

static void finalize_header(struct http_parser *hp);

static void parser_raise(VALUE klass, const char *msg)
{
  VALUE exc = rb_exc_new2(klass, msg);
  VALUE bt = rb_ary_new();

  rb_funcall(exc, id_set_backtrace, 1, bt);
  rb_exc_raise(exc);
}

static inline unsigned int ulong2uint(unsigned long n)
{
  unsigned int i = (unsigned int)n;

  if (sizeof(unsigned int) != sizeof(unsigned long)) {
    if ((unsigned long)i != n) {
      rb_raise(rb_eRangeError, "too large to be 32-bit uint: %lu", n);
    }
  }
  return i;
}

#define REMAINING (unsigned long)(pe - p)
#define LEN(AT, FPC) (ulong2uint(FPC - buffer) - hp->AT)
#define MARK(M,FPC) (hp->M = ulong2uint((FPC) - buffer))
#define PTR_TO(F) (buffer + hp->F)
#define STR_NEW(M,FPC) str_new(PTR_TO(M), LEN(M, FPC))
#define STRIPPED_STR_NEW(M,FPC) stripped_str_new(PTR_TO(M), LEN(M, FPC))

#define HP_FL_TEST(hp,fl) ((hp)->flags & (UH_FL_##fl))
#define HP_FL_SET(hp,fl) ((hp)->flags |= (UH_FL_##fl))
#define HP_FL_UNSET(hp,fl) ((hp)->flags &= ~(UH_FL_##fl))
#define HP_FL_ALL(hp,fl) (HP_FL_TEST(hp, fl) == (UH_FL_##fl))

static int is_lws(char c)
{
  return (c == ' ' || c == '\t');
}

static inline VALUE str_new(const char *str, long len)
{
    VALUE rb_str = rb_str_new(str, len);
    /* The Rack spec states:
    > If the string values for CGI keys contain non-ASCII characters, they should use ASCII-8BIT encoding.
    If they are ASCII, only the server is free to encode them as it wishes.
    We chose to encode them as UTF-8 as any reasonable application would expect that today, and having the
    same encoding as literal strings makes for slightly faster comparisons.
    We'd like to also encode other strings that would be valid UTF-8 into UTF-8, but that would
    violate the spec, so we leave them in BINARY aka ASCII-8BIT. */
    if (rb_enc_str_asciionly_p(rb_str)) {
        RB_ENCODING_SET_INLINED(rb_str, rb_utf8_encindex());
    }
    return rb_str;
}

static inline VALUE stripped_str_new(const char *str, long len)
{
  long end;

  for (end = len - 1; end >= 0 && is_lws(str[end]); end--);

  return str_new(str, end + 1);
}

/*
 * handles values of the "Connection:" header, keepalive is implied
 * for HTTP/1.1 but needs to be explicitly enabled with HTTP/1.0
 * Additionally, we require GET/HEAD requests to support keepalive.
 */
static void hp_keepalive_connection(struct http_parser *hp, VALUE val)
{
  if (STR_CSTR_CASE_EQ(val, "keep-alive")) {
    /* basically have HTTP/1.0 masquerade as HTTP/1.1+ */
    HP_FL_SET(hp, KAVERSION);
  } else if (STR_CSTR_CASE_EQ(val, "close")) {
    /*
     * it doesn't matter what HTTP version or request method we have,
     * if a client says "Connection: close", we disable keepalive
     */
    HP_FL_UNSET(hp, KAVERSION);
  } else {
    /*
     * client could've sent anything, ignore it for now.  Maybe
     * "HP_FL_UNSET(hp, KAVERSION);" just in case?
     * Raising an exception might be too mean...
     */
  }
}

static void
request_method(struct http_parser *hp, const char *ptr, size_t len)
{
  VALUE v = rb_str_new(ptr, len);

  rb_hash_aset(hp->env, g_request_method, v);
}

static void
http_version(struct http_parser *hp, const char *ptr, size_t len)
{
  VALUE v;

  HP_FL_SET(hp, HASHEADER);

  if (CONST_MEM_EQ("HTTP/1.1", ptr, len)) {
    /* HTTP/1.1 implies keepalive unless "Connection: close" is set */
    HP_FL_SET(hp, KAVERSION);
    v = g_http_11;
  } else if (CONST_MEM_EQ("HTTP/1.0", ptr, len)) {
    v = g_http_10;
  } else {
    v = rb_str_new(ptr, len);
  }
  rb_hash_aset(hp->env, g_server_protocol, v);
  rb_hash_aset(hp->env, g_http_version, v);
}

static void write_cont_value(struct http_parser *hp,
                             char *buffer, const char *p)
{
  char *vptr;
  long end;
  long len = LEN(mark, p);
  long cont_len;

  if (hp->cont == Qfalse)
     parser_raise(eHttpParserError, "invalid continuation line");
  if (NIL_P(hp->cont))
     return; /* we're ignoring this header (probably Host:) */

  assert(TYPE(hp->cont) == T_STRING && "continuation line is not a string");
  assert(hp->mark > 0 && "impossible continuation line offset");

  if (len == 0)
    return;

  cont_len = RSTRING_LEN(hp->cont);
  if (cont_len > 0) {
    --hp->mark;
    len = LEN(mark, p);
  }
  vptr = PTR_TO(mark);

  /* normalize tab to space */
  if (cont_len > 0) {
    assert((' ' == *vptr || '\t' == *vptr) && "invalid leading white space");
    *vptr = ' ';
  }

  for (end = len - 1; end >= 0 && is_lws(vptr[end]); end--);
  rb_str_buf_cat(hp->cont, vptr, end + 1);
}

static int is_chunked(VALUE v)
{
  /* common case first */
  if (STR_CSTR_CASE_EQ(v, "chunked"))
    return 1;

  /*
   * call Ruby function in pitchfork/http_parser.rb to deal with unlikely
   * comma-delimited case
   */
  return rb_funcall(cHttpParser, id_is_chunked_p, 1, v) != Qfalse;
}

static void write_value(VALUE self, struct http_parser *hp,
                        char *buffer, const char *p)
{
  VALUE f;
  char *field = PTR_TO(start.field);
  size_t i;
  VALUE target = hp->env;
  VALUE v;
  VALUE e;
  int in_trailer = HP_FL_TEST(hp, INTRAILER);

  /* Reject ambiguous framing headers before normalizing dashes for Rack. */
  if (CONST_MEM_EQ("CONTENT_LENGTH", field, hp->s.field_len))
    parser_raise(eHttpParserError, "invalid Content-Length");
  if (CONST_MEM_EQ("TRANSFER_ENCODING", field, hp->s.field_len))
    parser_raise(eHttpParserError, "invalid Transfer-Encoding");

  if (memchr(field, '_', hp->s.field_len)) {
    VALIDATE_MAX_LENGTH(hp->s.field_len, FIELD_NAME);
    VALIDATE_MAX_LENGTH(LEN(mark, p), FIELD_VALUE);
    RB_OBJ_WRITE(self, &hp->cont, Qnil);
    return;
  }

  for (i = 0; i < hp->s.field_len; i++)
    if (field[i] == '-')
      field[i] = '_';

  f = find_common_field(field, hp->s.field_len);

  VALIDATE_MAX_LENGTH(LEN(mark, p), FIELD_VALUE);
  if (in_trailer && (f == g_content_length ||
                     f == g_http_transfer_encoding || f == g_http_trailer))
    parser_raise(eHttpParserError, "invalid Trailer");

  v = LEN(mark, p) == 0 ? rb_str_buf_new(128) : STRIPPED_STR_NEW(mark, p);
  if (NIL_P(f)) {
    size_t flen = hp->s.field_len;

    VALIDATE_MAX_LENGTH(flen, FIELD_NAME);

    /*
     * ignore "Version" headers since they conflict with the HTTP_VERSION
     * rack env variable.
     */
    if (!in_trailer && CONST_MEM_EQ("VERSION", field, flen)) {
      RB_OBJ_WRITE(self, &hp->cont, Qnil);
      return;
    }
    f = uncommon_field(field, flen);
  } else if (!in_trailer && f == g_http_connection) {
    hp_keepalive_connection(hp, v);
  } else if (!in_trailer && f == g_content_length && !HP_FL_TEST(hp, CHUNKED)) {
    if (hp->len.content)
      parser_raise(eHttpParserError, "Content-Length already set");
    hp->len.content = parse_length(RSTRING_PTR(v), RSTRING_LEN(v));
    if (hp->len.content < 0)
      parser_raise(eHttpParserError, "invalid Content-Length");
    if (hp->len.content != 0)
      HP_FL_SET(hp, HASBODY);
  } else if (!in_trailer && f == g_http_transfer_encoding) {
    if (is_chunked(v)) {
      if (HP_FL_TEST(hp, CHUNKED))
        /*
         * RFC 7230 3.3.1:
         * A sender MUST NOT apply chunked more than once to a message body
         * (i.e., chunking an already chunked message is not allowed).
         */
        parser_raise(eHttpParserError, "Transfer-Encoding double chunked");

      HP_FL_SET(hp, CHUNKED);
      HP_FL_SET(hp, HASBODY);

      /* RFC 7230 3.3.3, 3: favor chunked if Content-Length exists */
      hp->len.content = 0;
    } else if (HP_FL_TEST(hp, CHUNKED)) {
      /*
       * RFC 7230 3.3.3, point 3 states:
       * If a Transfer-Encoding header field is present in a request and
       * the chunked transfer coding is not the final encoding, the
       * message body length cannot be determined reliably; the server
       * MUST respond with the 400 (Bad Request) status code and then
       * close the connection.
       */
      parser_raise(eHttpParserError, "invalid Transfer-Encoding");
    }
  } else if (!in_trailer && f == g_http_trailer) {
    HP_FL_SET(hp, HASTRAILER);
  } else {
    assert(TYPE(f) == T_STRING && "memoized object is not a string");
    assert_frozen(f);
  }

  if (in_trailer) {
    target = rb_hash_aref(hp->env, g_request_trailers);
    if (NIL_P(target)) {
      target = rb_hash_new();
      rb_hash_aset(hp->env, g_request_trailers, target);
    }
  }

  e = rb_hash_aref(target, f);
  if (NIL_P(e)) {
    RB_OBJ_WRITE(self, &hp->cont, rb_hash_aset(target, f, v));
  } else if (!in_trailer && f == g_http_host) {
    /*
     * ignored, absolute URLs in REQUEST_URI take precedence over
     * the Host: header (ref: rfc 2616, section 5.2.1)
     */
    RB_OBJ_WRITE(self, &hp->cont, Qnil);
  } else {
    rb_str_buf_cat(e, ",", 1);
    RB_OBJ_WRITE(self, &hp->cont, rb_str_buf_append(e, v));
  }
}

/** Machine **/


#line 453 "pitchfork_http.rl"


/** Data **/

#line 359 "pitchfork_http.c"
static const int http_parser_start = 1;
static const int http_parser_first_final = 122;
static const int http_parser_error = 0;

static const int http_parser_en_ChunkedBody = 100;
static const int http_parser_en_ChunkedBody_chunk_chunk_end = 105;
static const int http_parser_en_Trailers = 114;
static const int http_parser_en_main = 1;


#line 457 "pitchfork_http.rl"

static void http_parser_init(struct http_parser *hp)
{
  int cs = 0;
  hp->flags = 0;
  hp->mark = 0;
  hp->offset = 0;
  hp->start.field = 0;
  hp->s.field_len = 0;
  hp->len.content = 0;
  hp->cont = Qfalse; /* zero on MRI, should be optimized away by above */
  
#line 383 "pitchfork_http.c"
	{
	cs = http_parser_start;
	}

#line 469 "pitchfork_http.rl"
  hp->cs = cs;
}

/** exec **/
static void
http_parser_execute(VALUE self, struct http_parser *hp, char *buffer, size_t len)
{
  const char *p, *pe;
  int cs = hp->cs;
  size_t off = hp->offset;

  if (cs == http_parser_first_final)
    return;

  assert(off <= len && "offset past end of buffer");

  p = buffer+off;
  pe = buffer+len;

  assert((void *)(pe - p) == (void *)(len - off) &&
         "pointers aren't same distance");

  if (HP_FL_TEST(hp, INCHUNK)) {
    HP_FL_UNSET(hp, INCHUNK);
    goto skip_chunk_data_hack;
  }
  
#line 416 "pitchfork_http.c"
	{
	if ( p == pe )
		goto _test_eof;
	switch ( cs )
	{
case 1:
	switch( ( (unsigned char)*p) ) {
		case 33u: goto tr0;
		case 71u: goto tr2;
		case 124u: goto tr0;
		case 126u: goto tr0;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto tr0;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto tr0;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto tr0;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto tr0;
		} else
			goto tr0;
	} else
		goto tr0;
	goto st0;
st0:
cs = 0;
	goto _out;
tr0:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st2;
st2:
	if ( ++p == pe )
		goto _test_eof2;
case 2:
#line 458 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st49;
		case 124u: goto st49;
		case 126u: goto st49;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st49;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st49;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st49;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st49;
		} else
			goto st49;
	} else
		goto st49;
	goto st0;
tr3:
#line 364 "pitchfork_http.rl"
	{ request_method(hp, PTR_TO(mark), LEN(mark, p)); }
	goto st3;
st3:
	if ( ++p == pe )
		goto _test_eof3;
case 3:
#line 491 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 42u: goto tr5;
		case 47u: goto tr6;
		case 72u: goto tr7;
		case 104u: goto tr7;
	}
	goto st0;
tr5:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st4;
st4:
	if ( ++p == pe )
		goto _test_eof4;
case 4:
#line 507 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr8;
		case 35u: goto tr9;
	}
	goto st0;
tr8:
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st5;
tr41:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
#line 379 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), FRAGMENT);
    rb_hash_aset(hp->env, g_fragment, STR_NEW(mark, p));
  }
	goto st5;
tr44:
#line 379 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), FRAGMENT);
    rb_hash_aset(hp->env, g_fragment, STR_NEW(mark, p));
  }
	goto st5;
tr48:
#line 389 "pitchfork_http.rl"
	{
    VALUE val;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_PATH);
    val = rb_hash_aset(hp->env, g_request_path, STR_NEW(mark, p));

    rb_hash_aset(hp->env, g_path_info, val);
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st5;
tr54:
#line 383 "pitchfork_http.rl"
	{MARK(start.query, p); }
#line 384 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(start.query, p), QUERY_STRING);
    rb_hash_aset(hp->env, g_query_string, STR_NEW(start.query, p));
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st5;
tr58:
#line 384 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(start.query, p), QUERY_STRING);
    rb_hash_aset(hp->env, g_query_string, STR_NEW(start.query, p));
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st5;
st5:
	if ( ++p == pe )
		goto _test_eof5;
case 5:
#line 606 "pitchfork_http.c"
	if ( ( (unsigned char)*p) == 72u )
		goto tr10;
	goto st0;
tr10:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st6;
st6:
	if ( ++p == pe )
		goto _test_eof6;
case 6:
#line 618 "pitchfork_http.c"
	if ( ( (unsigned char)*p) == 84u )
		goto st7;
	goto st0;
st7:
	if ( ++p == pe )
		goto _test_eof7;
case 7:
	if ( ( (unsigned char)*p) == 84u )
		goto st8;
	goto st0;
st8:
	if ( ++p == pe )
		goto _test_eof8;
case 8:
	if ( ( (unsigned char)*p) == 80u )
		goto st9;
	goto st0;
st9:
	if ( ++p == pe )
		goto _test_eof9;
case 9:
	if ( ( (unsigned char)*p) == 47u )
		goto st10;
	goto st0;
st10:
	if ( ++p == pe )
		goto _test_eof10;
case 10:
	if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
		goto st11;
	goto st0;
st11:
	if ( ++p == pe )
		goto _test_eof11;
case 11:
	if ( ( (unsigned char)*p) == 46u )
		goto st12;
	if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
		goto st11;
	goto st0;
st12:
	if ( ++p == pe )
		goto _test_eof12;
case 12:
	if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
		goto st13;
	goto st0;
st13:
	if ( ++p == pe )
		goto _test_eof13;
case 13:
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr18;
		case 13u: goto tr19;
	}
	if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
		goto st13;
	goto st0;
tr18:
#line 388 "pitchfork_http.rl"
	{ http_version(hp, PTR_TO(mark), LEN(mark, p)); }
	goto st14;
tr25:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
#line 363 "pitchfork_http.rl"
	{ write_cont_value(hp, buffer, p); }
	goto st14;
tr30:
#line 363 "pitchfork_http.rl"
	{ write_cont_value(hp, buffer, p); }
	goto st14;
tr35:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
#line 362 "pitchfork_http.rl"
	{ write_value(self, hp, buffer, p); }
	goto st14;
tr39:
#line 362 "pitchfork_http.rl"
	{ write_value(self, hp, buffer, p); }
	goto st14;
st14:
	if ( ++p == pe )
		goto _test_eof14;
case 14:
#line 705 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 9u: goto st15;
		case 10u: goto tr21;
		case 13u: goto st18;
		case 32u: goto st15;
		case 33u: goto tr23;
		case 124u: goto tr23;
		case 126u: goto tr23;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto tr23;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto tr23;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto tr23;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto tr23;
		} else
			goto tr23;
	} else
		goto tr23;
	goto st0;
tr24:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
	goto st15;
st15:
	if ( ++p == pe )
		goto _test_eof15;
case 15:
#line 741 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 9u: goto tr24;
		case 10u: goto tr25;
		case 13u: goto tr26;
		case 32u: goto tr24;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto tr27;
tr19:
#line 388 "pitchfork_http.rl"
	{ http_version(hp, PTR_TO(mark), LEN(mark, p)); }
	goto st16;
tr26:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
#line 363 "pitchfork_http.rl"
	{ write_cont_value(hp, buffer, p); }
	goto st16;
tr31:
#line 363 "pitchfork_http.rl"
	{ write_cont_value(hp, buffer, p); }
	goto st16;
tr36:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
#line 362 "pitchfork_http.rl"
	{ write_value(self, hp, buffer, p); }
	goto st16;
tr40:
#line 362 "pitchfork_http.rl"
	{ write_value(self, hp, buffer, p); }
	goto st16;
st16:
	if ( ++p == pe )
		goto _test_eof16;
case 16:
#line 780 "pitchfork_http.c"
	if ( ( (unsigned char)*p) == 10u )
		goto st14;
	goto st0;
tr27:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
	goto st17;
st17:
	if ( ++p == pe )
		goto _test_eof17;
case 17:
#line 792 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr30;
		case 13u: goto tr31;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) > 8u ) {
		if ( 11u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 31u )
			goto st0;
	} else
		goto st0;
	goto st17;
tr21:
#line 402 "pitchfork_http.rl"
	{
    finalize_header(hp);

    cs = http_parser_first_final;
    if (HP_FL_TEST(hp, HASBODY)) {
      HP_FL_SET(hp, INBODY);
      if (HP_FL_TEST(hp, CHUNKED))
        cs = http_parser_en_ChunkedBody;
    } else {
      HP_FL_SET(hp, REQEOF);
      assert(!HP_FL_TEST(hp, CHUNKED) && "chunked encoding without body!");
    }
    /*
     * go back to Ruby so we can call the Rack application, we'll reenter
     * the parser iff the body needs to be processed.
     */
    goto post_exec;
  }
	goto st122;
tr104:
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
#line 402 "pitchfork_http.rl"
	{
    finalize_header(hp);

    cs = http_parser_first_final;
    if (HP_FL_TEST(hp, HASBODY)) {
      HP_FL_SET(hp, INBODY);
      if (HP_FL_TEST(hp, CHUNKED))
        cs = http_parser_en_ChunkedBody;
    } else {
      HP_FL_SET(hp, REQEOF);
      assert(!HP_FL_TEST(hp, CHUNKED) && "chunked encoding without body!");
    }
    /*
     * go back to Ruby so we can call the Rack application, we'll reenter
     * the parser iff the body needs to be processed.
     */
    goto post_exec;
  }
	goto st122;
tr107:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
#line 379 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), FRAGMENT);
    rb_hash_aset(hp->env, g_fragment, STR_NEW(mark, p));
  }
#line 402 "pitchfork_http.rl"
	{
    finalize_header(hp);

    cs = http_parser_first_final;
    if (HP_FL_TEST(hp, HASBODY)) {
      HP_FL_SET(hp, INBODY);
      if (HP_FL_TEST(hp, CHUNKED))
        cs = http_parser_en_ChunkedBody;
    } else {
      HP_FL_SET(hp, REQEOF);
      assert(!HP_FL_TEST(hp, CHUNKED) && "chunked encoding without body!");
    }
    /*
     * go back to Ruby so we can call the Rack application, we'll reenter
     * the parser iff the body needs to be processed.
     */
    goto post_exec;
  }
	goto st122;
tr111:
#line 379 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), FRAGMENT);
    rb_hash_aset(hp->env, g_fragment, STR_NEW(mark, p));
  }
#line 402 "pitchfork_http.rl"
	{
    finalize_header(hp);

    cs = http_parser_first_final;
    if (HP_FL_TEST(hp, HASBODY)) {
      HP_FL_SET(hp, INBODY);
      if (HP_FL_TEST(hp, CHUNKED))
        cs = http_parser_en_ChunkedBody;
    } else {
      HP_FL_SET(hp, REQEOF);
      assert(!HP_FL_TEST(hp, CHUNKED) && "chunked encoding without body!");
    }
    /*
     * go back to Ruby so we can call the Rack application, we'll reenter
     * the parser iff the body needs to be processed.
     */
    goto post_exec;
  }
	goto st122;
tr116:
#line 389 "pitchfork_http.rl"
	{
    VALUE val;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_PATH);
    val = rb_hash_aset(hp->env, g_request_path, STR_NEW(mark, p));

    rb_hash_aset(hp->env, g_path_info, val);
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
#line 402 "pitchfork_http.rl"
	{
    finalize_header(hp);

    cs = http_parser_first_final;
    if (HP_FL_TEST(hp, HASBODY)) {
      HP_FL_SET(hp, INBODY);
      if (HP_FL_TEST(hp, CHUNKED))
        cs = http_parser_en_ChunkedBody;
    } else {
      HP_FL_SET(hp, REQEOF);
      assert(!HP_FL_TEST(hp, CHUNKED) && "chunked encoding without body!");
    }
    /*
     * go back to Ruby so we can call the Rack application, we'll reenter
     * the parser iff the body needs to be processed.
     */
    goto post_exec;
  }
	goto st122;
tr123:
#line 383 "pitchfork_http.rl"
	{MARK(start.query, p); }
#line 384 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(start.query, p), QUERY_STRING);
    rb_hash_aset(hp->env, g_query_string, STR_NEW(start.query, p));
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
#line 402 "pitchfork_http.rl"
	{
    finalize_header(hp);

    cs = http_parser_first_final;
    if (HP_FL_TEST(hp, HASBODY)) {
      HP_FL_SET(hp, INBODY);
      if (HP_FL_TEST(hp, CHUNKED))
        cs = http_parser_en_ChunkedBody;
    } else {
      HP_FL_SET(hp, REQEOF);
      assert(!HP_FL_TEST(hp, CHUNKED) && "chunked encoding without body!");
    }
    /*
     * go back to Ruby so we can call the Rack application, we'll reenter
     * the parser iff the body needs to be processed.
     */
    goto post_exec;
  }
	goto st122;
tr128:
#line 384 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(start.query, p), QUERY_STRING);
    rb_hash_aset(hp->env, g_query_string, STR_NEW(start.query, p));
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
#line 402 "pitchfork_http.rl"
	{
    finalize_header(hp);

    cs = http_parser_first_final;
    if (HP_FL_TEST(hp, HASBODY)) {
      HP_FL_SET(hp, INBODY);
      if (HP_FL_TEST(hp, CHUNKED))
        cs = http_parser_en_ChunkedBody;
    } else {
      HP_FL_SET(hp, REQEOF);
      assert(!HP_FL_TEST(hp, CHUNKED) && "chunked encoding without body!");
    }
    /*
     * go back to Ruby so we can call the Rack application, we'll reenter
     * the parser iff the body needs to be processed.
     */
    goto post_exec;
  }
	goto st122;
st122:
	if ( ++p == pe )
		goto _test_eof122;
case 122:
#line 1032 "pitchfork_http.c"
	goto st0;
tr105:
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st18;
tr108:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
#line 379 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), FRAGMENT);
    rb_hash_aset(hp->env, g_fragment, STR_NEW(mark, p));
  }
	goto st18;
tr112:
#line 379 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), FRAGMENT);
    rb_hash_aset(hp->env, g_fragment, STR_NEW(mark, p));
  }
	goto st18;
tr117:
#line 389 "pitchfork_http.rl"
	{
    VALUE val;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_PATH);
    val = rb_hash_aset(hp->env, g_request_path, STR_NEW(mark, p));

    rb_hash_aset(hp->env, g_path_info, val);
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st18;
tr124:
#line 383 "pitchfork_http.rl"
	{MARK(start.query, p); }
#line 384 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(start.query, p), QUERY_STRING);
    rb_hash_aset(hp->env, g_query_string, STR_NEW(start.query, p));
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st18;
tr129:
#line 384 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(start.query, p), QUERY_STRING);
    rb_hash_aset(hp->env, g_query_string, STR_NEW(start.query, p));
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st18;
st18:
	if ( ++p == pe )
		goto _test_eof18;
case 18:
#line 1127 "pitchfork_http.c"
	if ( ( (unsigned char)*p) == 10u )
		goto tr21;
	goto st0;
tr23:
#line 357 "pitchfork_http.rl"
	{ MARK(start.field, p); }
#line 358 "pitchfork_http.rl"
	{ upcase_char(deconst(p)); }
	goto st19;
tr32:
#line 358 "pitchfork_http.rl"
	{ upcase_char(deconst(p)); }
	goto st19;
st19:
	if ( ++p == pe )
		goto _test_eof19;
case 19:
#line 1145 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 33u: goto tr32;
		case 58u: goto tr33;
		case 124u: goto tr32;
		case 126u: goto tr32;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto tr32;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto tr32;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto tr32;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto tr32;
		} else
			goto tr32;
	} else
		goto tr32;
	goto st0;
tr34:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
	goto st20;
tr33:
#line 360 "pitchfork_http.rl"
	{ hp->s.field_len = LEN(start.field, p); }
	goto st20;
st20:
	if ( ++p == pe )
		goto _test_eof20;
case 20:
#line 1182 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 9u: goto tr34;
		case 10u: goto tr35;
		case 13u: goto tr36;
		case 32u: goto tr34;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto tr37;
tr37:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
	goto st21;
st21:
	if ( ++p == pe )
		goto _test_eof21;
case 21:
#line 1201 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr39;
		case 13u: goto tr40;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) > 8u ) {
		if ( 11u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 31u )
			goto st0;
	} else
		goto st0;
	goto st21;
tr9:
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st22;
tr50:
#line 389 "pitchfork_http.rl"
	{
    VALUE val;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_PATH);
    val = rb_hash_aset(hp->env, g_request_path, STR_NEW(mark, p));

    rb_hash_aset(hp->env, g_path_info, val);
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st22;
tr56:
#line 383 "pitchfork_http.rl"
	{MARK(start.query, p); }
#line 384 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(start.query, p), QUERY_STRING);
    rb_hash_aset(hp->env, g_query_string, STR_NEW(start.query, p));
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st22;
tr60:
#line 384 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(start.query, p), QUERY_STRING);
    rb_hash_aset(hp->env, g_query_string, STR_NEW(start.query, p));
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st22;
st22:
	if ( ++p == pe )
		goto _test_eof22;
case 22:
#line 1290 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr41;
		case 35u: goto st0;
		case 37u: goto tr43;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto tr42;
tr42:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st23;
st23:
	if ( ++p == pe )
		goto _test_eof23;
case 23:
#line 1308 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr44;
		case 35u: goto st0;
		case 37u: goto st24;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto st23;
tr43:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st24;
st24:
	if ( ++p == pe )
		goto _test_eof24;
case 24:
#line 1326 "pitchfork_http.c"
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st25;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st25;
	} else
		goto st25;
	goto st0;
st25:
	if ( ++p == pe )
		goto _test_eof25;
case 25:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st23;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st23;
	} else
		goto st23;
	goto st0;
tr6:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st26;
tr76:
#line 368 "pitchfork_http.rl"
	{ rb_hash_aset(hp->env, g_http_host, STR_NEW(mark, p)); }
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st26;
st26:
	if ( ++p == pe )
		goto _test_eof26;
case 26:
#line 1363 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr48;
		case 35u: goto tr50;
		case 37u: goto st27;
		case 63u: goto tr52;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto st26;
st27:
	if ( ++p == pe )
		goto _test_eof27;
case 27:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st28;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st28;
	} else
		goto st28;
	goto st0;
st28:
	if ( ++p == pe )
		goto _test_eof28;
case 28:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st26;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st26;
	} else
		goto st26;
	goto st0;
tr52:
#line 389 "pitchfork_http.rl"
	{
    VALUE val;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_PATH);
    val = rb_hash_aset(hp->env, g_request_path, STR_NEW(mark, p));

    rb_hash_aset(hp->env, g_path_info, val);
  }
	goto st29;
st29:
	if ( ++p == pe )
		goto _test_eof29;
case 29:
#line 1415 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr54;
		case 35u: goto tr56;
		case 37u: goto tr57;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto tr55;
tr55:
#line 383 "pitchfork_http.rl"
	{MARK(start.query, p); }
	goto st30;
st30:
	if ( ++p == pe )
		goto _test_eof30;
case 30:
#line 1433 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr58;
		case 35u: goto tr60;
		case 37u: goto st31;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto st30;
tr57:
#line 383 "pitchfork_http.rl"
	{MARK(start.query, p); }
	goto st31;
st31:
	if ( ++p == pe )
		goto _test_eof31;
case 31:
#line 1451 "pitchfork_http.c"
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st32;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st32;
	} else
		goto st32;
	goto st0;
st32:
	if ( ++p == pe )
		goto _test_eof32;
case 32:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st30;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st30;
	} else
		goto st30;
	goto st0;
tr7:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
#line 359 "pitchfork_http.rl"
	{ downcase_char(deconst(p)); }
	goto st33;
st33:
	if ( ++p == pe )
		goto _test_eof33;
case 33:
#line 1484 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 84u: goto tr63;
		case 116u: goto tr63;
	}
	goto st0;
tr63:
#line 359 "pitchfork_http.rl"
	{ downcase_char(deconst(p)); }
	goto st34;
st34:
	if ( ++p == pe )
		goto _test_eof34;
case 34:
#line 1498 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 84u: goto tr64;
		case 116u: goto tr64;
	}
	goto st0;
tr64:
#line 359 "pitchfork_http.rl"
	{ downcase_char(deconst(p)); }
	goto st35;
st35:
	if ( ++p == pe )
		goto _test_eof35;
case 35:
#line 1512 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 80u: goto tr65;
		case 112u: goto tr65;
	}
	goto st0;
tr65:
#line 359 "pitchfork_http.rl"
	{ downcase_char(deconst(p)); }
	goto st36;
st36:
	if ( ++p == pe )
		goto _test_eof36;
case 36:
#line 1526 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 58u: goto tr66;
		case 83u: goto tr67;
		case 115u: goto tr67;
	}
	goto st0;
tr66:
#line 365 "pitchfork_http.rl"
	{
    rb_hash_aset(hp->env, g_rack_url_scheme, STR_NEW(mark, p));
  }
	goto st37;
st37:
	if ( ++p == pe )
		goto _test_eof37;
case 37:
#line 1543 "pitchfork_http.c"
	if ( ( (unsigned char)*p) == 47u )
		goto st38;
	goto st0;
st38:
	if ( ++p == pe )
		goto _test_eof38;
case 38:
	if ( ( (unsigned char)*p) == 47u )
		goto st39;
	goto st0;
st39:
	if ( ++p == pe )
		goto _test_eof39;
case 39:
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st41;
		case 47u: goto st0;
		case 60u: goto st0;
		case 91u: goto tr73;
		case 95u: goto tr72;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 32u ) {
			if ( 34u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 35u )
				goto st0;
		} else
			goto st0;
	} else if ( ( (unsigned char)*p) > 57u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 64u )
				goto st0;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto tr72;
		} else
			goto tr72;
	} else
		goto tr72;
	goto st40;
st40:
	if ( ++p == pe )
		goto _test_eof40;
case 40:
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st41;
		case 47u: goto st0;
		case 60u: goto st0;
		case 64u: goto st39;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 34u ) {
		if ( ( (unsigned char)*p) <= 32u )
			goto st0;
	} else if ( ( (unsigned char)*p) > 35u ) {
		if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
			goto st0;
	} else
		goto st0;
	goto st40;
st41:
	if ( ++p == pe )
		goto _test_eof41;
case 41:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st42;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st42;
	} else
		goto st42;
	goto st0;
st42:
	if ( ++p == pe )
		goto _test_eof42;
case 42:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st40;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st40;
	} else
		goto st40;
	goto st0;
tr72:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st43;
st43:
	if ( ++p == pe )
		goto _test_eof43;
case 43:
#line 1638 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st41;
		case 47u: goto tr76;
		case 58u: goto st44;
		case 60u: goto st0;
		case 64u: goto st39;
		case 95u: goto st43;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 32u ) {
			if ( 34u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 35u )
				goto st0;
		} else
			goto st0;
	} else if ( ( (unsigned char)*p) > 57u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
				goto st0;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st43;
		} else
			goto st43;
	} else
		goto st43;
	goto st40;
st44:
	if ( ++p == pe )
		goto _test_eof44;
case 44:
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st41;
		case 47u: goto tr76;
		case 60u: goto st0;
		case 64u: goto st39;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 34u ) {
		if ( ( (unsigned char)*p) <= 32u )
			goto st0;
	} else if ( ( (unsigned char)*p) > 35u ) {
		if ( ( (unsigned char)*p) > 57u ) {
			if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
				goto st0;
		} else if ( ( (unsigned char)*p) >= 48u )
			goto st44;
	} else
		goto st0;
	goto st40;
tr73:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st45;
st45:
	if ( ++p == pe )
		goto _test_eof45;
case 45:
#line 1697 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st41;
		case 47u: goto st0;
		case 60u: goto st0;
		case 64u: goto st39;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 48u ) {
		if ( ( (unsigned char)*p) > 32u ) {
			if ( 34u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 35u )
				goto st0;
		} else
			goto st0;
	} else if ( ( (unsigned char)*p) > 58u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
				goto st0;
		} else if ( ( (unsigned char)*p) > 70u ) {
			if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
				goto st46;
		} else
			goto st46;
	} else
		goto st46;
	goto st40;
st46:
	if ( ++p == pe )
		goto _test_eof46;
case 46:
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st41;
		case 47u: goto st0;
		case 60u: goto st0;
		case 64u: goto st39;
		case 93u: goto st47;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 48u ) {
		if ( ( (unsigned char)*p) > 32u ) {
			if ( 34u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 35u )
				goto st0;
		} else
			goto st0;
	} else if ( ( (unsigned char)*p) > 58u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
				goto st0;
		} else if ( ( (unsigned char)*p) > 70u ) {
			if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
				goto st46;
		} else
			goto st46;
	} else
		goto st46;
	goto st40;
st47:
	if ( ++p == pe )
		goto _test_eof47;
case 47:
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st41;
		case 47u: goto tr76;
		case 58u: goto st44;
		case 60u: goto st0;
		case 64u: goto st39;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 34u ) {
		if ( ( (unsigned char)*p) <= 32u )
			goto st0;
	} else if ( ( (unsigned char)*p) > 35u ) {
		if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
			goto st0;
	} else
		goto st0;
	goto st40;
tr67:
#line 359 "pitchfork_http.rl"
	{ downcase_char(deconst(p)); }
	goto st48;
st48:
	if ( ++p == pe )
		goto _test_eof48;
case 48:
#line 1782 "pitchfork_http.c"
	if ( ( (unsigned char)*p) == 58u )
		goto tr66;
	goto st0;
st49:
	if ( ++p == pe )
		goto _test_eof49;
case 49:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st50;
		case 124u: goto st50;
		case 126u: goto st50;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st50;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st50;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st50;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st50;
		} else
			goto st50;
	} else
		goto st50;
	goto st0;
st50:
	if ( ++p == pe )
		goto _test_eof50;
case 50:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st51;
		case 124u: goto st51;
		case 126u: goto st51;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st51;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st51;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st51;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st51;
		} else
			goto st51;
	} else
		goto st51;
	goto st0;
st51:
	if ( ++p == pe )
		goto _test_eof51;
case 51:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st52;
		case 124u: goto st52;
		case 126u: goto st52;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st52;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st52;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st52;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st52;
		} else
			goto st52;
	} else
		goto st52;
	goto st0;
st52:
	if ( ++p == pe )
		goto _test_eof52;
case 52:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st53;
		case 124u: goto st53;
		case 126u: goto st53;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st53;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st53;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st53;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st53;
		} else
			goto st53;
	} else
		goto st53;
	goto st0;
st53:
	if ( ++p == pe )
		goto _test_eof53;
case 53:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st54;
		case 124u: goto st54;
		case 126u: goto st54;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st54;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st54;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st54;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st54;
		} else
			goto st54;
	} else
		goto st54;
	goto st0;
st54:
	if ( ++p == pe )
		goto _test_eof54;
case 54:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st55;
		case 124u: goto st55;
		case 126u: goto st55;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st55;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st55;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st55;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st55;
		} else
			goto st55;
	} else
		goto st55;
	goto st0;
st55:
	if ( ++p == pe )
		goto _test_eof55;
case 55:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st56;
		case 124u: goto st56;
		case 126u: goto st56;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st56;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st56;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st56;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st56;
		} else
			goto st56;
	} else
		goto st56;
	goto st0;
st56:
	if ( ++p == pe )
		goto _test_eof56;
case 56:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st57;
		case 124u: goto st57;
		case 126u: goto st57;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st57;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st57;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st57;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st57;
		} else
			goto st57;
	} else
		goto st57;
	goto st0;
st57:
	if ( ++p == pe )
		goto _test_eof57;
case 57:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st58;
		case 124u: goto st58;
		case 126u: goto st58;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st58;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st58;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st58;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st58;
		} else
			goto st58;
	} else
		goto st58;
	goto st0;
st58:
	if ( ++p == pe )
		goto _test_eof58;
case 58:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st59;
		case 124u: goto st59;
		case 126u: goto st59;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st59;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st59;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st59;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st59;
		} else
			goto st59;
	} else
		goto st59;
	goto st0;
st59:
	if ( ++p == pe )
		goto _test_eof59;
case 59:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st60;
		case 124u: goto st60;
		case 126u: goto st60;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st60;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st60;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st60;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st60;
		} else
			goto st60;
	} else
		goto st60;
	goto st0;
st60:
	if ( ++p == pe )
		goto _test_eof60;
case 60:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st61;
		case 124u: goto st61;
		case 126u: goto st61;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st61;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st61;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st61;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st61;
		} else
			goto st61;
	} else
		goto st61;
	goto st0;
st61:
	if ( ++p == pe )
		goto _test_eof61;
case 61:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st62;
		case 124u: goto st62;
		case 126u: goto st62;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st62;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st62;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st62;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st62;
		} else
			goto st62;
	} else
		goto st62;
	goto st0;
st62:
	if ( ++p == pe )
		goto _test_eof62;
case 62:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st63;
		case 124u: goto st63;
		case 126u: goto st63;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st63;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st63;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st63;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st63;
		} else
			goto st63;
	} else
		goto st63;
	goto st0;
st63:
	if ( ++p == pe )
		goto _test_eof63;
case 63:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st64;
		case 124u: goto st64;
		case 126u: goto st64;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st64;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st64;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st64;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st64;
		} else
			goto st64;
	} else
		goto st64;
	goto st0;
st64:
	if ( ++p == pe )
		goto _test_eof64;
case 64:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st65;
		case 124u: goto st65;
		case 126u: goto st65;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st65;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st65;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st65;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st65;
		} else
			goto st65;
	} else
		goto st65;
	goto st0;
st65:
	if ( ++p == pe )
		goto _test_eof65;
case 65:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st66;
		case 124u: goto st66;
		case 126u: goto st66;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st66;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st66;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st66;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st66;
		} else
			goto st66;
	} else
		goto st66;
	goto st0;
st66:
	if ( ++p == pe )
		goto _test_eof66;
case 66:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st67;
		case 124u: goto st67;
		case 126u: goto st67;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st67;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st67;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st67;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st67;
		} else
			goto st67;
	} else
		goto st67;
	goto st0;
st67:
	if ( ++p == pe )
		goto _test_eof67;
case 67:
	if ( ( (unsigned char)*p) == 32u )
		goto tr3;
	goto st0;
tr2:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st68;
st68:
	if ( ++p == pe )
		goto _test_eof68;
case 68:
#line 2305 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st49;
		case 69u: goto st69;
		case 124u: goto st49;
		case 126u: goto st49;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st49;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st49;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st49;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st49;
		} else
			goto st49;
	} else
		goto st49;
	goto st0;
st69:
	if ( ++p == pe )
		goto _test_eof69;
case 69:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr3;
		case 33u: goto st50;
		case 84u: goto st70;
		case 124u: goto st50;
		case 126u: goto st50;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st50;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st50;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st50;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st50;
		} else
			goto st50;
	} else
		goto st50;
	goto st0;
st70:
	if ( ++p == pe )
		goto _test_eof70;
case 70:
	switch( ( (unsigned char)*p) ) {
		case 32u: goto tr100;
		case 33u: goto st51;
		case 124u: goto st51;
		case 126u: goto st51;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st51;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st51;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st51;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st51;
		} else
			goto st51;
	} else
		goto st51;
	goto st0;
tr100:
#line 364 "pitchfork_http.rl"
	{ request_method(hp, PTR_TO(mark), LEN(mark, p)); }
	goto st71;
st71:
	if ( ++p == pe )
		goto _test_eof71;
case 71:
#line 2396 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 42u: goto tr101;
		case 47u: goto tr102;
		case 72u: goto tr103;
		case 104u: goto tr103;
	}
	goto st0;
tr101:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st72;
st72:
	if ( ++p == pe )
		goto _test_eof72;
case 72:
#line 2412 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr104;
		case 13u: goto tr105;
		case 32u: goto tr8;
		case 35u: goto tr106;
	}
	goto st0;
tr106:
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st73;
tr119:
#line 389 "pitchfork_http.rl"
	{
    VALUE val;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_PATH);
    val = rb_hash_aset(hp->env, g_request_path, STR_NEW(mark, p));

    rb_hash_aset(hp->env, g_path_info, val);
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st73;
tr126:
#line 383 "pitchfork_http.rl"
	{MARK(start.query, p); }
#line 384 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(start.query, p), QUERY_STRING);
    rb_hash_aset(hp->env, g_query_string, STR_NEW(start.query, p));
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st73;
tr131:
#line 384 "pitchfork_http.rl"
	{
    VALIDATE_MAX_URI_LENGTH(LEN(start.query, p), QUERY_STRING);
    rb_hash_aset(hp->env, g_query_string, STR_NEW(start.query, p));
  }
#line 369 "pitchfork_http.rl"
	{
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, p));

    if (STR_CSTR_EQ(str, "*")) {
      rb_hash_aset(hp->env, g_path_info, str);
    }
  }
	goto st73;
st73:
	if ( ++p == pe )
		goto _test_eof73;
case 73:
#line 2497 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr107;
		case 13u: goto tr108;
		case 32u: goto tr41;
		case 35u: goto st0;
		case 37u: goto tr110;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto tr109;
tr109:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st74;
st74:
	if ( ++p == pe )
		goto _test_eof74;
case 74:
#line 2517 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr111;
		case 13u: goto tr112;
		case 32u: goto tr44;
		case 35u: goto st0;
		case 37u: goto st75;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto st74;
tr110:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st75;
st75:
	if ( ++p == pe )
		goto _test_eof75;
case 75:
#line 2537 "pitchfork_http.c"
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st76;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st76;
	} else
		goto st76;
	goto st0;
st76:
	if ( ++p == pe )
		goto _test_eof76;
case 76:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st74;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st74;
	} else
		goto st74;
	goto st0;
tr102:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st77;
tr147:
#line 368 "pitchfork_http.rl"
	{ rb_hash_aset(hp->env, g_http_host, STR_NEW(mark, p)); }
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st77;
st77:
	if ( ++p == pe )
		goto _test_eof77;
case 77:
#line 2574 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr116;
		case 13u: goto tr117;
		case 32u: goto tr48;
		case 35u: goto tr119;
		case 37u: goto st78;
		case 63u: goto tr121;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto st77;
st78:
	if ( ++p == pe )
		goto _test_eof78;
case 78:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st79;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st79;
	} else
		goto st79;
	goto st0;
st79:
	if ( ++p == pe )
		goto _test_eof79;
case 79:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st77;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st77;
	} else
		goto st77;
	goto st0;
tr121:
#line 389 "pitchfork_http.rl"
	{
    VALUE val;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, p), REQUEST_PATH);
    val = rb_hash_aset(hp->env, g_request_path, STR_NEW(mark, p));

    rb_hash_aset(hp->env, g_path_info, val);
  }
	goto st80;
st80:
	if ( ++p == pe )
		goto _test_eof80;
case 80:
#line 2628 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr123;
		case 13u: goto tr124;
		case 32u: goto tr54;
		case 35u: goto tr126;
		case 37u: goto tr127;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto tr125;
tr125:
#line 383 "pitchfork_http.rl"
	{MARK(start.query, p); }
	goto st81;
st81:
	if ( ++p == pe )
		goto _test_eof81;
case 81:
#line 2648 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr128;
		case 13u: goto tr129;
		case 32u: goto tr58;
		case 35u: goto tr131;
		case 37u: goto st82;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto st81;
tr127:
#line 383 "pitchfork_http.rl"
	{MARK(start.query, p); }
	goto st82;
st82:
	if ( ++p == pe )
		goto _test_eof82;
case 82:
#line 2668 "pitchfork_http.c"
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st83;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st83;
	} else
		goto st83;
	goto st0;
st83:
	if ( ++p == pe )
		goto _test_eof83;
case 83:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st81;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st81;
	} else
		goto st81;
	goto st0;
tr103:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
#line 359 "pitchfork_http.rl"
	{ downcase_char(deconst(p)); }
	goto st84;
st84:
	if ( ++p == pe )
		goto _test_eof84;
case 84:
#line 2701 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 84u: goto tr134;
		case 116u: goto tr134;
	}
	goto st0;
tr134:
#line 359 "pitchfork_http.rl"
	{ downcase_char(deconst(p)); }
	goto st85;
st85:
	if ( ++p == pe )
		goto _test_eof85;
case 85:
#line 2715 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 84u: goto tr135;
		case 116u: goto tr135;
	}
	goto st0;
tr135:
#line 359 "pitchfork_http.rl"
	{ downcase_char(deconst(p)); }
	goto st86;
st86:
	if ( ++p == pe )
		goto _test_eof86;
case 86:
#line 2729 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 80u: goto tr136;
		case 112u: goto tr136;
	}
	goto st0;
tr136:
#line 359 "pitchfork_http.rl"
	{ downcase_char(deconst(p)); }
	goto st87;
st87:
	if ( ++p == pe )
		goto _test_eof87;
case 87:
#line 2743 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 58u: goto tr137;
		case 83u: goto tr138;
		case 115u: goto tr138;
	}
	goto st0;
tr137:
#line 365 "pitchfork_http.rl"
	{
    rb_hash_aset(hp->env, g_rack_url_scheme, STR_NEW(mark, p));
  }
	goto st88;
st88:
	if ( ++p == pe )
		goto _test_eof88;
case 88:
#line 2760 "pitchfork_http.c"
	if ( ( (unsigned char)*p) == 47u )
		goto st89;
	goto st0;
st89:
	if ( ++p == pe )
		goto _test_eof89;
case 89:
	if ( ( (unsigned char)*p) == 47u )
		goto st90;
	goto st0;
st90:
	if ( ++p == pe )
		goto _test_eof90;
case 90:
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st92;
		case 47u: goto st0;
		case 60u: goto st0;
		case 91u: goto tr144;
		case 95u: goto tr143;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 32u ) {
			if ( 34u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 35u )
				goto st0;
		} else
			goto st0;
	} else if ( ( (unsigned char)*p) > 57u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 64u )
				goto st0;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto tr143;
		} else
			goto tr143;
	} else
		goto tr143;
	goto st91;
st91:
	if ( ++p == pe )
		goto _test_eof91;
case 91:
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st92;
		case 47u: goto st0;
		case 60u: goto st0;
		case 64u: goto st90;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 34u ) {
		if ( ( (unsigned char)*p) <= 32u )
			goto st0;
	} else if ( ( (unsigned char)*p) > 35u ) {
		if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
			goto st0;
	} else
		goto st0;
	goto st91;
st92:
	if ( ++p == pe )
		goto _test_eof92;
case 92:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st93;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st93;
	} else
		goto st93;
	goto st0;
st93:
	if ( ++p == pe )
		goto _test_eof93;
case 93:
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto st91;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto st91;
	} else
		goto st91;
	goto st0;
tr143:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st94;
st94:
	if ( ++p == pe )
		goto _test_eof94;
case 94:
#line 2855 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st92;
		case 47u: goto tr147;
		case 58u: goto st95;
		case 60u: goto st0;
		case 64u: goto st90;
		case 95u: goto st94;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 32u ) {
			if ( 34u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 35u )
				goto st0;
		} else
			goto st0;
	} else if ( ( (unsigned char)*p) > 57u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
				goto st0;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st94;
		} else
			goto st94;
	} else
		goto st94;
	goto st91;
st95:
	if ( ++p == pe )
		goto _test_eof95;
case 95:
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st92;
		case 47u: goto tr147;
		case 60u: goto st0;
		case 64u: goto st90;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 34u ) {
		if ( ( (unsigned char)*p) <= 32u )
			goto st0;
	} else if ( ( (unsigned char)*p) > 35u ) {
		if ( ( (unsigned char)*p) > 57u ) {
			if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
				goto st0;
		} else if ( ( (unsigned char)*p) >= 48u )
			goto st95;
	} else
		goto st0;
	goto st91;
tr144:
#line 355 "pitchfork_http.rl"
	{MARK(mark, p); }
	goto st96;
st96:
	if ( ++p == pe )
		goto _test_eof96;
case 96:
#line 2914 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st92;
		case 47u: goto st0;
		case 60u: goto st0;
		case 64u: goto st90;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 48u ) {
		if ( ( (unsigned char)*p) > 32u ) {
			if ( 34u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 35u )
				goto st0;
		} else
			goto st0;
	} else if ( ( (unsigned char)*p) > 58u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
				goto st0;
		} else if ( ( (unsigned char)*p) > 70u ) {
			if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
				goto st97;
		} else
			goto st97;
	} else
		goto st97;
	goto st91;
st97:
	if ( ++p == pe )
		goto _test_eof97;
case 97:
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st92;
		case 47u: goto st0;
		case 60u: goto st0;
		case 64u: goto st90;
		case 93u: goto st98;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 48u ) {
		if ( ( (unsigned char)*p) > 32u ) {
			if ( 34u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 35u )
				goto st0;
		} else
			goto st0;
	} else if ( ( (unsigned char)*p) > 58u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
				goto st0;
		} else if ( ( (unsigned char)*p) > 70u ) {
			if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
				goto st97;
		} else
			goto st97;
	} else
		goto st97;
	goto st91;
st98:
	if ( ++p == pe )
		goto _test_eof98;
case 98:
	switch( ( (unsigned char)*p) ) {
		case 37u: goto st92;
		case 47u: goto tr147;
		case 58u: goto st95;
		case 60u: goto st0;
		case 64u: goto st90;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) < 34u ) {
		if ( ( (unsigned char)*p) <= 32u )
			goto st0;
	} else if ( ( (unsigned char)*p) > 35u ) {
		if ( 62u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 63u )
			goto st0;
	} else
		goto st0;
	goto st91;
tr138:
#line 359 "pitchfork_http.rl"
	{ downcase_char(deconst(p)); }
	goto st99;
st99:
	if ( ++p == pe )
		goto _test_eof99;
case 99:
#line 2999 "pitchfork_http.c"
	if ( ( (unsigned char)*p) == 58u )
		goto tr137;
	goto st0;
st100:
	if ( ++p == pe )
		goto _test_eof100;
case 100:
	if ( ( (unsigned char)*p) == 48u )
		goto tr151;
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 49u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto tr152;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto tr152;
	} else
		goto tr152;
	goto st0;
tr151:
#line 397 "pitchfork_http.rl"
	{
    hp->len.chunk = step_incr(hp->len.chunk, ( (unsigned char)*p), 16);
    if (hp->len.chunk < 0)
      parser_raise(eHttpParserError, "invalid chunk size");
  }
	goto st101;
st101:
	if ( ++p == pe )
		goto _test_eof101;
case 101:
#line 3030 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr153;
		case 13u: goto st102;
		case 48u: goto tr151;
		case 59u: goto st111;
	}
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 49u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto tr152;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto tr152;
	} else
		goto tr152;
	goto st0;
tr153:
#line 426 "pitchfork_http.rl"
	{
    HP_FL_SET(hp, INTRAILER);
    RB_OBJ_WRITE(self, &hp->cont, Qfalse);
    cs = http_parser_en_Trailers;
    ++p;
    assert(p <= pe && "buffer overflow after chunked body");
    goto post_exec;
  }
	goto st123;
st123:
	if ( ++p == pe )
		goto _test_eof123;
case 123:
#line 3061 "pitchfork_http.c"
	goto st0;
st102:
	if ( ++p == pe )
		goto _test_eof102;
case 102:
	if ( ( (unsigned char)*p) == 10u )
		goto tr153;
	goto st0;
tr152:
#line 397 "pitchfork_http.rl"
	{
    hp->len.chunk = step_incr(hp->len.chunk, ( (unsigned char)*p), 16);
    if (hp->len.chunk < 0)
      parser_raise(eHttpParserError, "invalid chunk size");
  }
	goto st103;
st103:
	if ( ++p == pe )
		goto _test_eof103;
case 103:
#line 3082 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto st104;
		case 13u: goto st107;
		case 59u: goto st108;
	}
	if ( ( (unsigned char)*p) < 65u ) {
		if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
			goto tr152;
	} else if ( ( (unsigned char)*p) > 70u ) {
		if ( 97u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 102u )
			goto tr152;
	} else
		goto tr152;
	goto st0;
st104:
	if ( ++p == pe )
		goto _test_eof104;
case 104:
	goto tr159;
tr159:
#line 435 "pitchfork_http.rl"
	{
  skip_chunk_data_hack: {
    size_t nr = MIN((size_t)hp->len.chunk, REMAINING);
    memcpy(RSTRING_PTR(hp->cont) + hp->s.dest_offset, p, nr);
    hp->s.dest_offset += nr;
    hp->len.chunk -= nr;
    p += nr;
    assert(hp->len.chunk >= 0 && "negative chunk length");
    if ((size_t)hp->len.chunk > REMAINING) {
      HP_FL_SET(hp, INCHUNK);
      goto post_exec;
    } else {
      p--;
      {goto st105;}
    }
  }}
	goto st105;
st105:
	if ( ++p == pe )
		goto _test_eof105;
case 105:
#line 3125 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto st100;
		case 13u: goto st106;
	}
	goto st0;
st106:
	if ( ++p == pe )
		goto _test_eof106;
case 106:
	if ( ( (unsigned char)*p) == 10u )
		goto st100;
	goto st0;
st107:
	if ( ++p == pe )
		goto _test_eof107;
case 107:
	if ( ( (unsigned char)*p) == 10u )
		goto st104;
	goto st0;
st108:
	if ( ++p == pe )
		goto _test_eof108;
case 108:
	switch( ( (unsigned char)*p) ) {
		case 10u: goto st104;
		case 13u: goto st107;
		case 32u: goto st108;
		case 33u: goto st109;
		case 59u: goto st108;
		case 61u: goto st110;
		case 124u: goto st109;
		case 126u: goto st109;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st109;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st109;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st109;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st109;
		} else
			goto st109;
	} else
		goto st109;
	goto st0;
st109:
	if ( ++p == pe )
		goto _test_eof109;
case 109:
	switch( ( (unsigned char)*p) ) {
		case 10u: goto st104;
		case 13u: goto st107;
		case 33u: goto st109;
		case 59u: goto st108;
		case 61u: goto st110;
		case 124u: goto st109;
		case 126u: goto st109;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st109;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st109;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st109;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st109;
		} else
			goto st109;
	} else
		goto st109;
	goto st0;
st110:
	if ( ++p == pe )
		goto _test_eof110;
case 110:
	switch( ( (unsigned char)*p) ) {
		case 10u: goto st104;
		case 13u: goto st107;
		case 33u: goto st110;
		case 59u: goto st108;
		case 124u: goto st110;
		case 126u: goto st110;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st110;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st110;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st110;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st110;
		} else
			goto st110;
	} else
		goto st110;
	goto st0;
st111:
	if ( ++p == pe )
		goto _test_eof111;
case 111:
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr153;
		case 13u: goto st102;
		case 32u: goto st111;
		case 33u: goto st112;
		case 59u: goto st111;
		case 61u: goto st113;
		case 124u: goto st112;
		case 126u: goto st112;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st112;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st112;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st112;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st112;
		} else
			goto st112;
	} else
		goto st112;
	goto st0;
st112:
	if ( ++p == pe )
		goto _test_eof112;
case 112:
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr153;
		case 13u: goto st102;
		case 33u: goto st112;
		case 59u: goto st111;
		case 61u: goto st113;
		case 124u: goto st112;
		case 126u: goto st112;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st112;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st112;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st112;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st112;
		} else
			goto st112;
	} else
		goto st112;
	goto st0;
st113:
	if ( ++p == pe )
		goto _test_eof113;
case 113:
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr153;
		case 13u: goto st102;
		case 33u: goto st113;
		case 59u: goto st111;
		case 124u: goto st113;
		case 126u: goto st113;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto st113;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto st113;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto st113;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto st113;
		} else
			goto st113;
	} else
		goto st113;
	goto st0;
tr171:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
#line 363 "pitchfork_http.rl"
	{ write_cont_value(hp, buffer, p); }
	goto st114;
tr176:
#line 363 "pitchfork_http.rl"
	{ write_cont_value(hp, buffer, p); }
	goto st114;
tr181:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
#line 362 "pitchfork_http.rl"
	{ write_value(self, hp, buffer, p); }
	goto st114;
tr185:
#line 362 "pitchfork_http.rl"
	{ write_value(self, hp, buffer, p); }
	goto st114;
st114:
	if ( ++p == pe )
		goto _test_eof114;
case 114:
#line 3355 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 9u: goto st115;
		case 10u: goto tr167;
		case 13u: goto st118;
		case 32u: goto st115;
		case 33u: goto tr169;
		case 124u: goto tr169;
		case 126u: goto tr169;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto tr169;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto tr169;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto tr169;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto tr169;
		} else
			goto tr169;
	} else
		goto tr169;
	goto st0;
tr170:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
	goto st115;
st115:
	if ( ++p == pe )
		goto _test_eof115;
case 115:
#line 3391 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 9u: goto tr170;
		case 10u: goto tr171;
		case 13u: goto tr172;
		case 32u: goto tr170;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto tr173;
tr172:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
#line 363 "pitchfork_http.rl"
	{ write_cont_value(hp, buffer, p); }
	goto st116;
tr177:
#line 363 "pitchfork_http.rl"
	{ write_cont_value(hp, buffer, p); }
	goto st116;
tr182:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
#line 362 "pitchfork_http.rl"
	{ write_value(self, hp, buffer, p); }
	goto st116;
tr186:
#line 362 "pitchfork_http.rl"
	{ write_value(self, hp, buffer, p); }
	goto st116;
st116:
	if ( ++p == pe )
		goto _test_eof116;
case 116:
#line 3426 "pitchfork_http.c"
	if ( ( (unsigned char)*p) == 10u )
		goto st114;
	goto st0;
tr173:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
	goto st117;
st117:
	if ( ++p == pe )
		goto _test_eof117;
case 117:
#line 3438 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr176;
		case 13u: goto tr177;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) > 8u ) {
		if ( 11u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 31u )
			goto st0;
	} else
		goto st0;
	goto st117;
tr167:
#line 421 "pitchfork_http.rl"
	{
    cs = http_parser_first_final;
    goto post_exec;
  }
	goto st124;
st124:
	if ( ++p == pe )
		goto _test_eof124;
case 124:
#line 3461 "pitchfork_http.c"
	goto st0;
st118:
	if ( ++p == pe )
		goto _test_eof118;
case 118:
	if ( ( (unsigned char)*p) == 10u )
		goto tr167;
	goto st0;
tr169:
#line 357 "pitchfork_http.rl"
	{ MARK(start.field, p); }
#line 358 "pitchfork_http.rl"
	{ upcase_char(deconst(p)); }
	goto st119;
tr178:
#line 358 "pitchfork_http.rl"
	{ upcase_char(deconst(p)); }
	goto st119;
st119:
	if ( ++p == pe )
		goto _test_eof119;
case 119:
#line 3484 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 33u: goto tr178;
		case 58u: goto tr179;
		case 124u: goto tr178;
		case 126u: goto tr178;
	}
	if ( ( (unsigned char)*p) < 45u ) {
		if ( ( (unsigned char)*p) > 39u ) {
			if ( 42u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 43u )
				goto tr178;
		} else if ( ( (unsigned char)*p) >= 35u )
			goto tr178;
	} else if ( ( (unsigned char)*p) > 46u ) {
		if ( ( (unsigned char)*p) < 65u ) {
			if ( 48u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 57u )
				goto tr178;
		} else if ( ( (unsigned char)*p) > 90u ) {
			if ( 94u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 122u )
				goto tr178;
		} else
			goto tr178;
	} else
		goto tr178;
	goto st0;
tr180:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
	goto st120;
tr179:
#line 360 "pitchfork_http.rl"
	{ hp->s.field_len = LEN(start.field, p); }
	goto st120;
st120:
	if ( ++p == pe )
		goto _test_eof120;
case 120:
#line 3521 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 9u: goto tr180;
		case 10u: goto tr181;
		case 13u: goto tr182;
		case 32u: goto tr180;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) <= 31u )
		goto st0;
	goto tr183;
tr183:
#line 361 "pitchfork_http.rl"
	{ MARK(mark, p); }
	goto st121;
st121:
	if ( ++p == pe )
		goto _test_eof121;
case 121:
#line 3540 "pitchfork_http.c"
	switch( ( (unsigned char)*p) ) {
		case 10u: goto tr185;
		case 13u: goto tr186;
		case 127u: goto st0;
	}
	if ( ( (unsigned char)*p) > 8u ) {
		if ( 11u <= ( (unsigned char)*p) && ( (unsigned char)*p) <= 31u )
			goto st0;
	} else
		goto st0;
	goto st121;
	}
	_test_eof2: cs = 2; goto _test_eof; 
	_test_eof3: cs = 3; goto _test_eof; 
	_test_eof4: cs = 4; goto _test_eof; 
	_test_eof5: cs = 5; goto _test_eof; 
	_test_eof6: cs = 6; goto _test_eof; 
	_test_eof7: cs = 7; goto _test_eof; 
	_test_eof8: cs = 8; goto _test_eof; 
	_test_eof9: cs = 9; goto _test_eof; 
	_test_eof10: cs = 10; goto _test_eof; 
	_test_eof11: cs = 11; goto _test_eof; 
	_test_eof12: cs = 12; goto _test_eof; 
	_test_eof13: cs = 13; goto _test_eof; 
	_test_eof14: cs = 14; goto _test_eof; 
	_test_eof15: cs = 15; goto _test_eof; 
	_test_eof16: cs = 16; goto _test_eof; 
	_test_eof17: cs = 17; goto _test_eof; 
	_test_eof122: cs = 122; goto _test_eof; 
	_test_eof18: cs = 18; goto _test_eof; 
	_test_eof19: cs = 19; goto _test_eof; 
	_test_eof20: cs = 20; goto _test_eof; 
	_test_eof21: cs = 21; goto _test_eof; 
	_test_eof22: cs = 22; goto _test_eof; 
	_test_eof23: cs = 23; goto _test_eof; 
	_test_eof24: cs = 24; goto _test_eof; 
	_test_eof25: cs = 25; goto _test_eof; 
	_test_eof26: cs = 26; goto _test_eof; 
	_test_eof27: cs = 27; goto _test_eof; 
	_test_eof28: cs = 28; goto _test_eof; 
	_test_eof29: cs = 29; goto _test_eof; 
	_test_eof30: cs = 30; goto _test_eof; 
	_test_eof31: cs = 31; goto _test_eof; 
	_test_eof32: cs = 32; goto _test_eof; 
	_test_eof33: cs = 33; goto _test_eof; 
	_test_eof34: cs = 34; goto _test_eof; 
	_test_eof35: cs = 35; goto _test_eof; 
	_test_eof36: cs = 36; goto _test_eof; 
	_test_eof37: cs = 37; goto _test_eof; 
	_test_eof38: cs = 38; goto _test_eof; 
	_test_eof39: cs = 39; goto _test_eof; 
	_test_eof40: cs = 40; goto _test_eof; 
	_test_eof41: cs = 41; goto _test_eof; 
	_test_eof42: cs = 42; goto _test_eof; 
	_test_eof43: cs = 43; goto _test_eof; 
	_test_eof44: cs = 44; goto _test_eof; 
	_test_eof45: cs = 45; goto _test_eof; 
	_test_eof46: cs = 46; goto _test_eof; 
	_test_eof47: cs = 47; goto _test_eof; 
	_test_eof48: cs = 48; goto _test_eof; 
	_test_eof49: cs = 49; goto _test_eof; 
	_test_eof50: cs = 50; goto _test_eof; 
	_test_eof51: cs = 51; goto _test_eof; 
	_test_eof52: cs = 52; goto _test_eof; 
	_test_eof53: cs = 53; goto _test_eof; 
	_test_eof54: cs = 54; goto _test_eof; 
	_test_eof55: cs = 55; goto _test_eof; 
	_test_eof56: cs = 56; goto _test_eof; 
	_test_eof57: cs = 57; goto _test_eof; 
	_test_eof58: cs = 58; goto _test_eof; 
	_test_eof59: cs = 59; goto _test_eof; 
	_test_eof60: cs = 60; goto _test_eof; 
	_test_eof61: cs = 61; goto _test_eof; 
	_test_eof62: cs = 62; goto _test_eof; 
	_test_eof63: cs = 63; goto _test_eof; 
	_test_eof64: cs = 64; goto _test_eof; 
	_test_eof65: cs = 65; goto _test_eof; 
	_test_eof66: cs = 66; goto _test_eof; 
	_test_eof67: cs = 67; goto _test_eof; 
	_test_eof68: cs = 68; goto _test_eof; 
	_test_eof69: cs = 69; goto _test_eof; 
	_test_eof70: cs = 70; goto _test_eof; 
	_test_eof71: cs = 71; goto _test_eof; 
	_test_eof72: cs = 72; goto _test_eof; 
	_test_eof73: cs = 73; goto _test_eof; 
	_test_eof74: cs = 74; goto _test_eof; 
	_test_eof75: cs = 75; goto _test_eof; 
	_test_eof76: cs = 76; goto _test_eof; 
	_test_eof77: cs = 77; goto _test_eof; 
	_test_eof78: cs = 78; goto _test_eof; 
	_test_eof79: cs = 79; goto _test_eof; 
	_test_eof80: cs = 80; goto _test_eof; 
	_test_eof81: cs = 81; goto _test_eof; 
	_test_eof82: cs = 82; goto _test_eof; 
	_test_eof83: cs = 83; goto _test_eof; 
	_test_eof84: cs = 84; goto _test_eof; 
	_test_eof85: cs = 85; goto _test_eof; 
	_test_eof86: cs = 86; goto _test_eof; 
	_test_eof87: cs = 87; goto _test_eof; 
	_test_eof88: cs = 88; goto _test_eof; 
	_test_eof89: cs = 89; goto _test_eof; 
	_test_eof90: cs = 90; goto _test_eof; 
	_test_eof91: cs = 91; goto _test_eof; 
	_test_eof92: cs = 92; goto _test_eof; 
	_test_eof93: cs = 93; goto _test_eof; 
	_test_eof94: cs = 94; goto _test_eof; 
	_test_eof95: cs = 95; goto _test_eof; 
	_test_eof96: cs = 96; goto _test_eof; 
	_test_eof97: cs = 97; goto _test_eof; 
	_test_eof98: cs = 98; goto _test_eof; 
	_test_eof99: cs = 99; goto _test_eof; 
	_test_eof100: cs = 100; goto _test_eof; 
	_test_eof101: cs = 101; goto _test_eof; 
	_test_eof123: cs = 123; goto _test_eof; 
	_test_eof102: cs = 102; goto _test_eof; 
	_test_eof103: cs = 103; goto _test_eof; 
	_test_eof104: cs = 104; goto _test_eof; 
	_test_eof105: cs = 105; goto _test_eof; 
	_test_eof106: cs = 106; goto _test_eof; 
	_test_eof107: cs = 107; goto _test_eof; 
	_test_eof108: cs = 108; goto _test_eof; 
	_test_eof109: cs = 109; goto _test_eof; 
	_test_eof110: cs = 110; goto _test_eof; 
	_test_eof111: cs = 111; goto _test_eof; 
	_test_eof112: cs = 112; goto _test_eof; 
	_test_eof113: cs = 113; goto _test_eof; 
	_test_eof114: cs = 114; goto _test_eof; 
	_test_eof115: cs = 115; goto _test_eof; 
	_test_eof116: cs = 116; goto _test_eof; 
	_test_eof117: cs = 117; goto _test_eof; 
	_test_eof124: cs = 124; goto _test_eof; 
	_test_eof118: cs = 118; goto _test_eof; 
	_test_eof119: cs = 119; goto _test_eof; 
	_test_eof120: cs = 120; goto _test_eof; 
	_test_eof121: cs = 121; goto _test_eof; 

	_test_eof: {}
	_out: {}
	}

#line 496 "pitchfork_http.rl"
post_exec: /* "_out:" also goes here */
  if (hp->cs != http_parser_error)
    hp->cs = cs;
  hp->offset = ulong2uint(p - buffer);

  assert(p <= pe && "buffer overflow after parsing execute");
  assert(hp->offset <= len && "offset longer than length");
}

static void hp_mark(void *ptr)
{
  struct http_parser *hp = ptr;

  rb_gc_mark(hp->buf);
  rb_gc_mark(hp->env);
  rb_gc_mark(hp->cont);
}

static size_t hp_memsize(const void *ptr)
{
  return sizeof(struct http_parser);
}

static const rb_data_type_t hp_type = {
    .wrap_struct_name = "pitchfork_http_parser",
    .function = {
        .dmark = hp_mark,
        .dfree = RUBY_TYPED_DEFAULT_FREE,
        .dsize = hp_memsize,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED
};

static struct http_parser *data_get(VALUE self)
{
  struct http_parser *hp;

  TypedData_Get_Struct(self, struct http_parser, &hp_type, hp);
  assert(hp && "failed to extract http_parser struct");
  return hp;
}

/*
 * set rack.url_scheme to "https" or "http", no others are allowed by Rack
 * this resembles the Rack::Request#scheme method as of rack commit
 * 35bb5ba6746b5d346de9202c004cc926039650c7
 */
static void set_url_scheme(VALUE env, VALUE *server_port)
{
  VALUE scheme = rb_hash_aref(env, g_rack_url_scheme);

  if (NIL_P(scheme)) {
    /*
     * would anybody be horribly opposed to removing the X-Forwarded-SSL
     * and X-Forwarded-Proto handling from this parser?  We've had it
     * forever and nobody has said anything against it, either.
     * Anyways, please send comments to our public mailing list:
     * pitchfork-public@yhbt.net (no HTML mail, no subscription necessary)
     */
    scheme = rb_hash_aref(env, g_http_x_forwarded_ssl);
    if (!NIL_P(scheme) && STR_CSTR_EQ(scheme, "on")) {
      *server_port = g_port_443;
      scheme = g_https;
    } else {
      scheme = rb_hash_aref(env, g_http_x_forwarded_proto);
      if (NIL_P(scheme)) {
        scheme = g_http;
      } else {
        long len = RSTRING_LEN(scheme);
        if (len >= 5 && !memcmp(RSTRING_PTR(scheme), "https", 5)) {
          if (len != 5)
            scheme = g_https;
          *server_port = g_port_443;
        } else {
          scheme = g_http;
        }
      }
    }
    rb_hash_aset(env, g_rack_url_scheme, scheme);
  } else if (STR_CSTR_EQ(scheme, "https")) {
    *server_port = g_port_443;
  } else {
    assert(*server_port == g_port_80 && "server_port not set");
  }
}

/*
 * Parse and set the SERVER_NAME and SERVER_PORT variables
 * Not supporting X-Forwarded-Host/X-Forwarded-Port in here since
 * anybody who needs them is using an unsupported configuration and/or
 * incompetent.  Rack::Request will handle X-Forwarded-{Port,Host} just
 * fine.
 */
static void set_server_vars(VALUE env, VALUE *server_port)
{
  VALUE server_name = g_localhost;
  VALUE host = rb_hash_aref(env, g_http_host);

  if (!NIL_P(host)) {
    char *host_ptr = RSTRING_PTR(host);
    long host_len = RSTRING_LEN(host);
    char *colon;

    if (*host_ptr == '[') { /* ipv6 address format */
      char *rbracket = memchr(host_ptr + 1, ']', host_len - 1);

      if (rbracket)
        colon = (rbracket[1] == ':') ? rbracket + 1 : NULL;
      else
        colon = memchr(host_ptr + 1, ':', host_len - 1);
    } else {
      colon = memchr(host_ptr, ':', host_len);
    }

    if (colon) {
      long port_start = colon - host_ptr + 1;

      server_name = rb_str_substr(host, 0, colon - host_ptr);
      if ((host_len - port_start) > 0)
        *server_port = rb_str_substr(host, port_start, host_len);
    } else {
      server_name = host;
    }
  }
  rb_hash_aset(env, g_server_name, server_name);
  rb_hash_aset(env, g_server_port, *server_port);
}

static void finalize_header(struct http_parser *hp)
{
  VALUE server_port = g_port_80;

  set_url_scheme(hp->env, &server_port);
  set_server_vars(hp->env, &server_port);

  if (!HP_FL_TEST(hp, HASHEADER))
    rb_hash_aset(hp->env, g_server_protocol, g_http_09);

  /* rack requires QUERY_STRING */
  if (NIL_P(rb_hash_aref(hp->env, g_query_string)))
    rb_hash_aset(hp->env, g_query_string, rb_str_new(NULL, 0));
}

static VALUE HttpParser_alloc(VALUE klass)
{
  struct http_parser *hp;

  return TypedData_Make_Struct(klass, struct http_parser, &hp_type, hp);
}

#ifndef HAVE_RB_HASH_NEW_CAPA
static inline VALUE rb_hash_new_capa(long capa) {
    return rb_hash_new();
}
#endif

/**
 * call-seq:
 *    parser.new => parser
 *
 * Creates a new parser.
 */
static VALUE HttpParser_init(VALUE self)
{
  struct http_parser *hp = data_get(self);

  http_parser_init(hp);
  RB_OBJ_WRITE(self, &hp->buf, rb_str_new(NULL, 0));
  RB_OBJ_WRITE(self, &hp->env, rb_hash_new_capa(32)); // Even the simplest request will have 10 keys

  return self;
}

/**
 * call-seq:
 *    parser.clear => parser
 *
 * Resets the parser to it's initial state so that you can reuse it
 * rather than making new ones.
 */
static VALUE HttpParser_clear(VALUE self)
{
  struct http_parser *hp = data_get(self);

  /* we can't safely reuse .buf and .env if hijacked */
  if (HP_FL_TEST(hp, HIJACK))
    return HttpParser_init(self);

  http_parser_init(hp);
  rb_hash_clear(hp->env);

  return self;
}

static void advance_str(VALUE str, off_t nr)
{
  long len = RSTRING_LEN(str);

  if (len == 0)
    return;

  rb_str_modify(str);

  assert(nr <= len && "trying to advance past end of buffer");
  len -= nr;
  if (len > 0) /* unlikely, len is usually 0 */
    memmove(RSTRING_PTR(str), RSTRING_PTR(str) + nr, len);
  rb_str_set_len(str, len);
}

/**
 * call-seq:
 *   parser.content_length => nil or Integer
 *
 * Returns the number of bytes left to run through HttpParser#filter_body.
 * This will initially be the value of the "Content-Length" HTTP header
 * after header parsing is complete and will decrease in value as
 * HttpParser#filter_body is called for each chunk.  This should return
 * zero for requests with no body.
 *
 * This will return nil on "Transfer-Encoding: chunked" requests.
 */
static VALUE HttpParser_content_length(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return HP_FL_TEST(hp, CHUNKED) ? Qnil : OFFT2NUM(hp->len.content);
}

/**
 * Document-method: parse
 * call-seq:
 *    parser.parse => env or nil
 *
 * Takes a Hash and a String of data, parses the String of data filling
 * in the Hash returning the Hash if parsing is finished, nil otherwise
 * When returning the env Hash, it may modify data to point to where
 * body processing should begin.
 *
 * Raises HttpParserError if there are parsing errors.
 */
static VALUE HttpParser_parse(VALUE self)
{
  struct http_parser *hp = data_get(self);
  VALUE data = hp->buf;

  if (HP_FL_TEST(hp, TO_CLEAR))
    HttpParser_clear(self);

  http_parser_execute(self, hp, RSTRING_PTR(data), RSTRING_LEN(data));
  if (hp->offset > MAX_HEADER_LEN)
    parser_raise(e413, "HTTP header is too large");

  if (hp->cs == http_parser_first_final ||
      hp->cs == http_parser_en_ChunkedBody) {
    advance_str(data, hp->offset + 1);
    hp->offset = 0;
    if (HP_FL_TEST(hp, INTRAILER))
      HP_FL_SET(hp, REQEOF);

    return hp->env;
  }

  if (hp->cs == http_parser_error)
    parser_raise(eHttpParserError, "Invalid HTTP format, parsing fails.");

  return Qnil;
}

/**
 * Document-method: parse
 * call-seq:
 *    parser.add_parse(buffer) => env or nil
 *
 * adds the contents of +buffer+ to the internal buffer and attempts to
 * continue parsing.  Returns the +env+ Hash on success or nil if more
 * data is needed.
 *
 * Raises HttpParserError if there are parsing errors.
 */
static VALUE HttpParser_add_parse(VALUE self, VALUE buffer)
{
  struct http_parser *hp = data_get(self);

  Check_Type(buffer, T_STRING);
  rb_str_buf_append(hp->buf, buffer);

  return HttpParser_parse(self);
}

/**
 * Document-method: trailers
 * call-seq:
 *    parser.trailers(req, data) => req or nil
 *
 * This is an alias for HttpParser#headers
 */

/**
 * Document-method: headers
 */
static VALUE HttpParser_headers(VALUE self, VALUE env, VALUE buf)
{
  struct http_parser *hp = data_get(self);

  RB_OBJ_WRITE(self, &hp->buf, buf);
  RB_OBJ_WRITE(self, &hp->env, env);

  return HttpParser_parse(self);
}

static int chunked_eof(struct http_parser *hp)
{
  return ((hp->cs == http_parser_first_final) || HP_FL_TEST(hp, INTRAILER));
}

/**
 * call-seq:
 *    parser.body_eof? => true or false
 *
 * Detects if we're done filtering the body or not.  This can be used
 * to detect when to stop calling HttpParser#filter_body.
 */
static VALUE HttpParser_body_eof(VALUE self)
{
  struct http_parser *hp = data_get(self);

  if (HP_FL_TEST(hp, CHUNKED))
    return chunked_eof(hp) ? Qtrue : Qfalse;

  return hp->len.content == 0 ? Qtrue : Qfalse;
}

/**
 * call-seq:
 *    parser.keepalive? => true or false
 *
 * This should be used to detect if a request can really handle
 * keepalives and pipelining.  Currently, the rules are:
 *
 * 1. MUST be a GET or HEAD request
 * 2. MUST be HTTP/1.1 +or+ HTTP/1.0 with "Connection: keep-alive"
 * 3. MUST NOT have "Connection: close" set
 */
static VALUE HttpParser_keepalive(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return HP_FL_ALL(hp, KEEPALIVE) ? Qtrue : Qfalse;
}

/**
 * call-seq:
 *    parser.next? => true or false
 *
 * Exactly like HttpParser#keepalive?, except it will reset the internal
 * parser state on next parse if it returns true.
 */
static VALUE HttpParser_next(VALUE self)
{
  struct http_parser *hp = data_get(self);

  if (HP_FL_ALL(hp, KEEPALIVE)) {
    HP_FL_SET(hp, TO_CLEAR);
    return Qtrue;
  }
  return Qfalse;
}

/**
 * call-seq:
 *    parser.headers? => true or false
 *
 * This should be used to detect if a request has headers (and if
 * the response will have headers as well).  HTTP/0.9 requests
 * should return false, all subsequent HTTP versions will return true
 */
static VALUE HttpParser_has_headers(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return HP_FL_TEST(hp, HASHEADER) ? Qtrue : Qfalse;
}

static VALUE HttpParser_buf(VALUE self)
{
  return data_get(self)->buf;
}

static VALUE HttpParser_env(VALUE self)
{
  return data_get(self)->env;
}

static VALUE HttpParser_hijacked_bang(VALUE self)
{
  struct http_parser *hp = data_get(self);

  HP_FL_SET(hp, HIJACK);

  return self;
}

/**
 * call-seq:
 *    parser.filter_body(dst, src) => nil/src
 *
 * Takes a String of +src+, will modify data if dechunking is done.
 * Returns +nil+ if there is more data left to process.  Returns
 * +src+ if body processing is complete. When returning +src+,
 * it may modify +src+ so the start of the string points to where
 * the body ended so that trailer processing can begin.
 *
 * Raises HttpParserError if there are dechunking errors.
 * Basically this is a glorified memcpy(3) that copies +src+
 * into +buf+ while filtering it through the dechunker.
 */
static VALUE HttpParser_filter_body(VALUE self, VALUE dst, VALUE src)
{
  struct http_parser *hp = data_get(self);
  char *srcptr;
  long srclen;

  srcptr = RSTRING_PTR(src);
  srclen = RSTRING_LEN(src);

  StringValue(dst);

  if (HP_FL_TEST(hp, CHUNKED)) {
    if (!chunked_eof(hp)) {
      rb_str_modify(dst);
      rb_str_set_len(dst, 0);
      rb_str_modify_expand(dst, srclen); /* we can never copy more than srclen bytes */

      hp->s.dest_offset = 0;
      RB_OBJ_WRITE(self, &hp->cont, dst);
      RB_OBJ_WRITE(self, &hp->buf, src);
      http_parser_execute(self, hp, srcptr, srclen);
      if (hp->cs == http_parser_error)
        parser_raise(eHttpParserError, "Invalid HTTP format, parsing fails.");

      assert(hp->s.dest_offset <= hp->offset &&
             "destination buffer overflow");
      /*
       * set the decoded length before advance_str can allocate: GC
       * compaction may re-embed dst and only copies its logical length
       */
      rb_str_set_len(dst, hp->s.dest_offset);
      advance_str(src, hp->offset);

      if (RSTRING_LEN(dst) == 0 && chunked_eof(hp)) {
        assert(hp->len.chunk == 0 && "chunk at EOF but more to parse");
      } else {
        src = Qnil;
      }
    }
  } else {
    /* no need to enter the Ragel machine for unchunked transfers */
    assert(hp->len.content >= 0 && "negative Content-Length");
    if (hp->len.content > 0) {
      long nr = MIN(srclen, hp->len.content);

      rb_str_modify(dst);
      rb_str_resize(dst, nr);
      /*
       * using rb_str_replace() to avoid memcpy() doesn't help in
       * most cases because a GC-aware programmer will pass an explicit
       * buffer to env["rack.input"].read and reuse the buffer in a loop.
       * This causes copy-on-write behavior to be triggered anyways
       * when the +src+ buffer is modified (when reading off the socket).
       */
      RB_OBJ_WRITE(self, &hp->buf, src);
      memcpy(RSTRING_PTR(dst), srcptr, nr);
      hp->len.content -= nr;
      if (hp->len.content == 0) {
        HP_FL_SET(hp, REQEOF);
        hp->cs = http_parser_first_final;
      }
      advance_str(src, nr);
      src = Qnil;
    }
  }
  hp->offset = 0; /* for trailer parsing */
  return src;
}

static VALUE HttpParser_rssset(VALUE self, VALUE boolean)
{
  struct http_parser *hp = data_get(self);

  if (RTEST(boolean))
    HP_FL_SET(hp, RESSTART);
  else
    HP_FL_UNSET(hp, RESSTART);

  return boolean; /* ignored by Ruby anyways */
}

static VALUE HttpParser_rssget(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return HP_FL_TEST(hp, RESSTART) ? Qtrue : Qfalse;
}

#define SET_GLOBAL(var,str) do { \
  var = find_common_field(str, sizeof(str) - 1); \
  assert(!NIL_P(var) && "missed global field"); \
} while (0)

RUBY_FUNC_EXPORTED void Init_pitchfork_http(void)
{
  VALUE mPitchfork;

  mPitchfork = rb_define_module("Pitchfork");
  cHttpParser = rb_define_class_under(mPitchfork, "HttpParser", rb_cObject);
  eHttpParserError =
         rb_define_class_under(mPitchfork, "HttpParserError", rb_eIOError);
  e413 = rb_define_class_under(mPitchfork, "RequestEntityTooLargeError",
                               eHttpParserError);
  e414 = rb_define_class_under(mPitchfork, "RequestURITooLongError",
                               eHttpParserError);

  id_uminus = rb_intern("-@");
  init_globals();
  rb_define_alloc_func(cHttpParser, HttpParser_alloc);
  rb_define_method(cHttpParser, "initialize", HttpParser_init, 0);
  rb_define_method(cHttpParser, "clear", HttpParser_clear, 0);
  rb_define_method(cHttpParser, "parse", HttpParser_parse, 0);
  rb_define_method(cHttpParser, "add_parse", HttpParser_add_parse, 1);
  rb_define_method(cHttpParser, "headers", HttpParser_headers, 2);
  rb_define_method(cHttpParser, "trailers", HttpParser_headers, 2);
  rb_define_method(cHttpParser, "filter_body", HttpParser_filter_body, 2);
  rb_define_method(cHttpParser, "content_length", HttpParser_content_length, 0);
  rb_define_method(cHttpParser, "body_eof?", HttpParser_body_eof, 0);
  rb_define_method(cHttpParser, "keepalive?", HttpParser_keepalive, 0);
  rb_define_method(cHttpParser, "headers?", HttpParser_has_headers, 0);
  rb_define_method(cHttpParser, "next?", HttpParser_next, 0);
  rb_define_method(cHttpParser, "buf", HttpParser_buf, 0);
  rb_define_method(cHttpParser, "env", HttpParser_env, 0);
  rb_define_method(cHttpParser, "hijacked!", HttpParser_hijacked_bang, 0);
  rb_define_method(cHttpParser, "response_start_sent=", HttpParser_rssset, 1);
  rb_define_method(cHttpParser, "response_start_sent", HttpParser_rssget, 0);

  /*
   * The maximum size a single chunk when using chunked transfer encoding.
   * This is only a theoretical maximum used to detect errors in clients,
   * it is highly unlikely to encounter clients that send more than
   * several kilobytes at once.
   */
  rb_define_const(cHttpParser, "CHUNK_MAX", OFFT2NUM(UH_OFF_T_MAX));

  /*
   * The maximum size of the body as specified by Content-Length.
   * This is only a theoretical maximum, the actual limit is subject
   * to the limits of the file system used for +Dir.tmpdir+.
   */
  rb_define_const(cHttpParser, "LENGTH_MAX", OFFT2NUM(UH_OFF_T_MAX));

  init_common_fields();
  SET_GLOBAL(g_http_host, "HOST");
  SET_GLOBAL(g_http_trailer, "TRAILER");
  SET_GLOBAL(g_http_transfer_encoding, "TRANSFER_ENCODING");
  SET_GLOBAL(g_content_length, "CONTENT_LENGTH");
  SET_GLOBAL(g_http_connection, "CONNECTION");
  id_set_backtrace = rb_intern("set_backtrace");
  init_pitchfork_httpdate();

  id_is_chunked_p = rb_intern("is_chunked?");

  init_epollexclusive(mPitchfork);
  init_child_subreaper(mPitchfork);
  init_pitchfork_memory_page(mPitchfork);
}
#undef SET_GLOBAL
