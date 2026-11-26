' phext-data-stub.bas - an empty volume include for libphext-bas
' consumers that carry no data volume. Defines phLoadVolume with
' an empty volume; the store starts zeroed. Replace with real
' phextwrap output to ship initial scroll content.
phLoadVolume:
phVol$ = ""
RETURN
