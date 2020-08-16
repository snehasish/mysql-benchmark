SHELL := /bin/bash -o pipefail

COMPILER_INSTALL_BIN ?=${HOME}/working/llvm-propeller/plo/stage1/install/bin
DDIR := $(shell pwd)
MYSQL_SOURCE ?=$(DDIR)/../
ITERATIONS ?= 25

ifeq ($(J_NUMBER),)
CORES := $(shell grep ^cpu\\scores /proc/cpuinfo | uniq |  awk '{print $$4}')
THREADS  := $(shell grep -Ee "^core id" /proc/cpuinfo | wc -l)
THREAD_PER_CORE := $(shell echo $$(($(THREADS) / $(CORES))))
# leave some cores on the machine for other jobs.
USED_CORES := $(shell \
	if [[ "$(CORES)" -lt "3" ]] ; then \
	  echo 1 ; \
	elif [[ "$(CORES)" -lt "9" ]] ; then \
	  echo $$(($(CORES) * 3 / 4)) ; \
	else echo $$(($(CORES) * 7 / 8)); \
	fi )
J_NUMBER := $(shell echo $$(( $(USED_CORES) * $(THREAD_PER_CORE))))
endif

gen_compiler_flags  = -DCMAKE_C_FLAGS=$(1) -DCMAKE_CXX_FLAGS=$(1)
gen_linker_flags    = -DCMAKE_EXE_LINKER_FLAGS=$(1) -DCMAKE_SHARED_LINKER_FLAGS=$(1) -DCMAKE_MODULE_LINKER_FLAGS=$(1)
common_compiler_flags :=-fuse-ld=lld -DDBUG_OFF -ffunction-sections -fdata-sections -O3 -DNDEBUG -Qunused-arguments
common_linker_flags :=-Wl,-z,keep-text-section-prefix -Wl,--optimize-bb-jumps
# $1 are compiler cluster.
# $2 are ld flags.
gen_build_flags = $(call gen_compiler_flags,"$(1) $(common_compiler_flags)") $(call gen_linker_flags,"$(2) $(common_linker_flags)")


define build_mysql
	$(eval __comp_dir=$(DDIR)/$(shell echo $@ | sed -Ee 's!([^/]+)/.*!\1!'))
	if [[ -z "$(__comp_dir)" ]]; then echo "Invalid dir name" ; exit 1; fi
	echo "Building in directory: $(__comp_dir) ... " ;
	if [[ ! -e "$(__comp_dir)/build/CMakeCache.txt" ]]; then \
	    mkdir -p $(__comp_dir)/build ;                       \
	    cd $(__comp_dir)/build && cmake --debug-trycompile -G Ninja             \
		-DCMAKE_INSTALL_PREFIX=$(__comp_dir)/install     			 \
 		-DCMAKE_LINKER="lld"                                   \
		-DDOWNLOAD_BOOST=1                                    \
		-DWITH_BOOST=$(DDIR)/boost                           \
		-DCMAKE_BUILD_TYPE=None 															\
		-DCMAKE_C_COMPILER="$(COMPILER_INSTALL_BIN)/clang"        \
		-DCMAKE_CXX_COMPILER="$(COMPILER_INSTALL_BIN)/clang++"    \
		-DCMAKE_ASM_COMPILER="$(COMPILER_INSTALL_BIN)/clang"      \
		$(1)                                                      \
		$(MYSQL_SOURCE); \
	fi
	ninja install -j$(J_NUMBER) -C $(__comp_dir)/build $(3) 2>&1 | tee $(DDIR)/$(shell basename $(__comp_dir)).autolog || exit 1
	touch $@
endef

define setup_mysql
	$(eval __comp_dir=$(DDIR)/$(shell echo $@ | sed -Ee 's!([^/]+)/.*!\1!'))
	if [[ -z "$(__comp_dir)" ]]; then echo "Invalid dir name" ; exit 1; fi
	echo "Setup in directory: $(__comp_dir) ... " ;
	mkdir -p $(__comp_dir)/install/mysql-files && \
	echo "[mysqld]" > $(__comp_dir)/my.cnf && \
	echo "default-authentication-plugin=mysql_native_password" >> $(__comp_dir)/my.cnf && \
	$(__comp_dir)/install/bin/mysqld --defaults-file=$(__comp_dir)/my.cnf --initialize-insecure --user=${USER}
endef

# $(1) - The name of the test from /usr/share/sysbench/*.lua, eg oltp_read_only
# $(2) - The number of iterations
# $(3) - The table size to use
# $(4) - The number of events to use
# $(5) - Additional args to pass to the run phase.
define run_loadtest
	sysbench $(1) --table-size=$(3) --num-threads=1 --rand-type=uniform --rand-seed=1 --db-driver=mysql \
		--mysql-db=sysbench --tables=1 --mysql-socket=/tmp/mysql.sock --mysql-user=root prepare
	@{ if [[ "$(3)" -ge "10000" ]]; then \
		sysbench $(1) --table-size=$(3) --tables=1 --num-threads=1 --rand-type=uniform --rand-seed=1 --db-driver=mysql \
			--mysql-db=sysbench --mysql-socket=/tmp/mysql.sock --mysql-user=root prewarm; \
	fi; }
	@echo "Running test: $(1) $(2)x"
	@{ for i in {1..$(2)}; do \
		sysbench $(1) --table-size=$(3) --tables=1 --num-threads=1 --rand-type=uniform --rand-seed=1 --db-driver=mysql \
			--events=$(4) --time=0 --rate=0 $(5) \
			--mysql-db=sysbench --mysql-socket=/tmp/mysql.sock --mysql-user=root run &> $@.$(1).$$i.sysbench; \
	done; }
	sysbench $(1) --table-size=$(3) --tables=1 --num-threads=1 --rand-type=uniform --rand-seed=1 --db-driver=mysql \
		--mysql-db=sysbench --mysql-socket=/tmp/mysql.sock --mysql-user=root cleanup
endef

# The plain version is used for all commands such as admin and sending queries.
# Only the mysqld binary from the others are used.
plain/install/bin/mysqld:
	$(call build_mysql, $(call gen_build_flags))
	$(call setup_mysql)

mysql: plain/install/bin/mysqld
	ln -sf plain/install/bin/mysql $@
	touch $@

mysqladmin: plain/install/bin/mysqld
	ln -sf plain/install/bin/mysqladmin $@
	touch $@

# The remaining rules are for the different flavours of mysqld
stage-pgo/install/bin/mysqld: mysql mysqladmin
	$(call build_mysql,-DFPROFILE_GENERATE=ON $(call gen_build_flags))
	$(call setup_mysql)

pgo-vanilla/install/bin/mysqld: mysql mysqladmin default.profdata
	$(call build_mysql,-DFPROFILE_USE=ON -DFPROFILE_DIR=$(DDIR) $(call gen_build_flags))
	$(call setup_mysql)

stage-pgo-mysqld pgo-vanilla-mysqld plain-mysqld: %-mysqld: %/install/bin/mysqld
	ln -sf $< $@
	touch $@

stage-pgo-training: stage-pgo-mysqld
	@echo "Start server stage-pgo"
	@{ ./stage-pgo-mysqld &> $<.log & }
	@echo "Waiting 10s for server to start"
	@sleep 10
	@echo "Running training load"
	./mysql -u root -e "DROP DATABASE IF EXISTS sysbench; CREATE DATABASE sysbench;"
	# Keep the table size < 10000 to avoid prewarm during fdo training.
	$(call run_loadtest,oltp_read_write,1,2000,500)
	$(call run_loadtest,oltp_update_index,1,2000,500)
	$(call run_loadtest,oltp_delete,1,2000,500)
	$(call run_loadtest,select_random_ranges,1,2000,500)
	@echo "Shutdown server"
	./mysqladmin -u root shutdown

benchmark-%: mysql mysqladmin
	$(eval FLAVOR = $(shell echo $@ | sed -n -e 's/benchmark-//p'))
	@echo "Start server ${FLAVOR}"
	@{ ./${FLAVOR}-mysqld &> $<.log & }
	@echo "Waiting 10s for server to start"
	@sleep 10
	@echo "Running benchmark"
	./mysql -u root -e "DROP DATABASE IF EXISTS sysbench; CREATE DATABASE sysbench;"
	$(call run_loadtest,oltp_read_only,${ITERATIONS},500000,30000,--range_selects=off --skip_trx)
	@echo "Shutdown server"
	./mysqladmin -u root shutdown

default.profdata: stage-pgo-training
	$(COMPILER_INSTALL_BIN)/llvm-profdata merge -o default.profdata stage-pgo/profile-data

.PHONY: clean clean-all

clean:
	# links
	rm -f mysql mysqladmin *-mysqld
	# dirs
	rm -rf plain stage-pgo pgo-vanilla
	# logs
	rm -f *.autolog *.log *.sysbench
	# profiles
	rm -f *.profdata

clean-all: clean
	rm -rf boost

