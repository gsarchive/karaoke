build:
	pike ../augment.pike -d=~/Music/kar/alice --copy *.txt

publish: build
	cp *.kar ../../live/british/alice/alice/kar/
	rm ../../live/british/alice/alice/alice_karaoke.zip
	zip ../../live/british/alice/alice/alice_karaoke.zip *.kar *.mid
