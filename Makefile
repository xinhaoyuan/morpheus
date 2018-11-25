PROJECT = morpheus
DEPS = firedrill

ifdef DEP_LOCAL

ifdef FD_LOCAL_PATH
dep_firedrill = cp ${FD_LOCAL_PATH}
else
dep_firedrill = cp ../firedrill
endif

else
dep_firedrill = git https://github.com/xinhaoyuan/firedrill.git
endif

include erlang.mk
