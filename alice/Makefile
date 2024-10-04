build:
	pike ../augment.pike -d=~/Music/kar/alice *.txt

publish: build
	cp *.kar ../../live/british/alice/alice/kar/
	zip ../../live/british/alice/alice/alice_karaoke.zip *.kar
