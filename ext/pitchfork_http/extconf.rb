# -*- encoding: binary -*-
require 'mkmf'

have_const("PR_SET_CHILD_SUBREAPER", "sys/prctl.h")

message('checking if String#-@ (str_uminus) dedupes... ')
begin
  a = -(%w(t e s t).join)
  b = -(%w(t e s t).join)
  if a.equal?(b)
    $CPPFLAGS += ' -DSTR_UMINUS_DEDUPE=1 '
    message("yes\n")
  else
    $CPPFLAGS += ' -DSTR_UMINUS_DEDUPE=0 '
    message("no, needs Ruby 2.5+\n")
  end
rescue NoMethodError
  $CPPFLAGS += ' -DSTR_UMINUS_DEDUPE=0 '
  message("no, String#-@ not available\n")
end

have_func('epoll_create1', %w(sys/epoll.h))
create_makefile("pitchfork_http")
