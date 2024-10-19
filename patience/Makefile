build:
	pike ../augment.pike -d=~/Music/kar/Patience *.txt

publish: build
	rm ../../live/patience/webop/midi/patience_orch.zip
	zip ../../live/patience/webop/midi/patience_orch.zip *.kar *.mid
