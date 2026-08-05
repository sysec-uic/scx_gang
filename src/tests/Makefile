CXXFLAGS = -O3 -std=c++20 -Wall -Werror -pedantic

all: sb sb_sense sb_group sb_group_plus litmus

sb: sb.cpp
	g++ $(CXXFLAGS) $< -o $@

sb_sense: sb_sense.cpp sense_barrier.h
	g++ $(CXXFLAGS) $< -o $@

sb_group: sb_group.cpp
	g++ $(CXXFLAGS) $< -lbpf -o $@

sb_group_plus: sb_group_plus.cpp sense_barrier.h
	g++ $(CXXFLAGS) $< -lbpf -o $@

# Generalized harness: -t SB|MP|LB|2+2W|IRIW, -g for gang opt-in.
litmus: litmus.cpp sense_barrier.h
	g++ $(CXXFLAGS) $< -lbpf -o $@

# For hosts without libbpf (e.g. ARM boards): no -g gang opt-in.
litmus_nobpf: litmus.cpp sense_barrier.h
	g++ $(CXXFLAGS) -DNO_BPF $< -o $@

clean:
	rm -f sb sb_sense sb_group sb_group_plus litmus litmus_nobpf
