TextBufferCore = require '../src/text-buffer-core'

describe "Marker", ->
  [buffer, markerCreations] = []
  beforeEach ->
    buffer = new TextBufferCore(text: "abcdefghijklmnopqrstuvwxyz")
    markerCreations = []
    buffer.on 'marker-created', (marker) -> markerCreations.push(marker)

  describe "creation", ->
    describe "TextBufferCore::markRange(range, properties)", ->
      it "creates a marker for the given range with the given properties", ->
        marker = buffer.markRange([[0, 3], [0, 6]])
        expect(marker.getRange()).toEqual [[0, 3], [0, 6]]
        expect(marker.getHeadPosition()).toEqual [0, 6]
        expect(marker.getTailPosition()).toEqual [0, 3]
        expect(marker.isReversed()).toBe false
        expect(marker.hasTail()).toBe true
        expect(markerCreations).toEqual [marker]
