NVCC = nvcc
INC = ./src
OPTS = -O3 -std=c++14 -I$(INC)

SRCS = src/argparse.cpp src/io.cpp src/kmeans.cpp src/kmeans_seq.cpp

EXEC = bin/kmeans

all: clean compile

compile:
	$(NVCC) $(SRCS) $(OPTS) -o $(EXEC)

clean:
	rm -f $(EXEC)
