## MySQL Compiler Benchmark
Scripts to build mysqld with a custom clang compiler, additional compiler options and feedback directed optimizations.
Also includes benchmarking using sysbench oltp_* scripts.

## Usage 
1. Download mysql-server-mysql-8.0.21
  a. git clone git@github.com:mysql/mysql-server.git
  b. git fetch --all --tags
  c. git checkout tags/mysql-8.0.21 -b mysql-8.0.21-branch
2. Patch the cmake files using `lld_build.patch` provided.
3. Install prerequisites: sysbench libssl-dev bison. 
4. Copy the makefile into a new directory in the root of mysql source.
5. Build the fdo optimized version using `make pgo-vanilla-mysqld`
