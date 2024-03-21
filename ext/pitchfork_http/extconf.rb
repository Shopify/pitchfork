# -*- encoding: binary -*-
# frozen_string_literal: true
require 'mkmf'

have_const("PR_SET_CHILD_SUBREAPER", "sys/prctl.h")
have_func("rb_enc_interned_str", "ruby.h") # Ruby 3.0+
have_func("rb_io_descriptor", "ruby.h") # Ruby 3.1+

if RUBY_VERSION.start_with?('3.0.')
  # https://bugs.ruby-lang.org/issues/18772
  $CFLAGS << ' -DRB_ENC_INTERNED_STR_NULL_CHECK=1 '
else
  $CFLAGS << ' -DRB_ENC_INTERNED_STR_NULL_CHECK=0 '
end

have_func('epoll_create1', %w(sys/epoll.h))
create_makefile("pitchfork/pitchfork_http")
