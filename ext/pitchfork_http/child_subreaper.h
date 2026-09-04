#include "ruby.h"
#ifdef HAVE_CONST_PR_SET_CHILD_SUBREAPER
#include <sys/prctl.h>

static VALUE enable_child_subreaper(VALUE module) {
  int status = -1;
  if (prctl(PR_GET_CHILD_SUBREAPER, &status) < 0) {
    return Qfalse;
  }
  if (prctl(PR_SET_CHILD_SUBREAPER, 1) < 0) {
    rb_sys_fail("prctl(2) PR_SET_CHILD_SUBREAPER");
  }
  return Qtrue;
}
#else
static VALUE enable_child_subreaper(VALUE module) {
  return Qfalse;
}
#endif

void init_child_subreaper(VALUE mPitchfork)
{
#ifdef HAVE_CONST_PR_SET_CHILD_SUBREAPER
  int status = -1;
  int ret = prctl(PR_GET_CHILD_SUBREAPER, &status);
  rb_define_const(mPitchfork, "CHILD_SUBREAPER_AVAILABLE", ret < 0 ? Qfalse : Qtrue);
#else
  rb_define_const(mPitchfork, "CHILD_SUBREAPER_AVAILABLE", Qfalse);
#endif
  rb_define_singleton_method(mPitchfork, "enable_child_subreaper", enable_child_subreaper, 0);
}
