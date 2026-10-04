NVCC = nvcc
INC = ./src

# sm_60 is the floor for atomicAdd on double, and -arch keeps the ptx so a newer card still runs
OPTS = -O3 -std=c++14 -arch=sm_60 -I$(INC)

SRCS = src/argparse.cpp src/io.cpp src/kmeans.cpp src/kmeans_seq.cpp src/kmeans_cuda.cu \
       src/kmeans_thrust.cu

EXEC = bin/kmeans

all: clean compile

compile:
	$(NVCC) $(SRCS) $(OPTS) -o $(EXEC)

clean:
	rm -f $(EXEC)
