.SUFFIXES: .erl .beam .yrl

CC=erlc
OUTDIR = .
MODS= di2mpd2

$(OUTDIR)/%.beam:       %.erl
	$(CC) $(EFLAGS) $<

all: ${MODS:%=%.beam}

clean:
	rm -f *.beam ./*.beam ./erl_crash.dump \#* *~

start:
	erl -noshell -s di2mpd2 start
