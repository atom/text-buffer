TextBuffer = require '../src/text-buffer'
Point = require '../src/point'
Range = require '../src/range'
SampleText = require './helpers/sample-text'

describe "DisplayMarkerLayer", ->
  it "allows DisplayMarkers to be created and manipulated in screen coordinates", ->
    buffer = new TextBuffer(text: '\ta\tbc\tdef\tg\n\th')
    displayLayer = buffer.addDisplayLayer(tabLength: 4)
    markerLayer = displayLayer.addMarkerLayer()

    marker = markerLayer.markScreenRange([[0, 4], [1, 4]])
    expect(marker.getScreenRange()).toEqual [[0, 4], [1, 4]]
    expect(marker.getBufferRange()).toEqual [[0, 1], [1, 1]]

    markerChangeEvents = []
    marker.onDidChange (change) -> markerChangeEvents.push(change)

    marker.setScreenRange([[0, 5], [1, 0]])

    expect(marker.getBufferRange()).toEqual([[0, 2], [1, 0]])
    expect(marker.getScreenRange()).toEqual([[0, 5], [1, 0]])
    expect(markerChangeEvents[0]).toEqual {
      oldHeadBufferPosition: [1, 1]
      newHeadBufferPosition: [1, 0]
      oldTailBufferPosition: [0, 1]
      newTailBufferPosition: [0, 2]
      oldHeadScreenPosition: [1, 4]
      newHeadScreenPosition: [1, 0]
      oldTailScreenPosition: [0, 4]
      newTailScreenPosition: [0, 5]
      wasValid: true
      isValid: true
      textChanged: false
    }

    markerChangeEvents = []
    buffer.insert([0, 0], '\t')

    expect(marker.getBufferRange()).toEqual([[0, 3], [1, 0]])
    expect(marker.getScreenRange()).toEqual([[0, 9], [1, 0]])
    expect(markerChangeEvents).toEqual [{
      oldHeadBufferPosition: [1, 0]
      newHeadBufferPosition: [1, 0]
      oldTailBufferPosition: [0, 2]
      newTailBufferPosition: [0, 3]
      oldHeadScreenPosition: [1, 0]
      newHeadScreenPosition: [1, 0]
      oldTailScreenPosition: [0, 5]
      newTailScreenPosition: [0, 9]
      wasValid: true
      isValid: true
      textChanged: true
    }]

    expect(markerLayer.getMarker(marker.id)).toBe marker

  it "emits events when markers are created and destroyed", ->
    buffer = new TextBuffer(text: 'hello world')
    displayLayer = buffer.addDisplayLayer(tabLength: 4)
    markerLayer = displayLayer.addMarkerLayer()
    createdMarkers = []
    markerLayer.onDidCreateMarker (m) -> createdMarkers.push(m)
    marker = markerLayer.markScreenRange([[0, 4], [1, 4]])

    expect(createdMarkers).toEqual [marker]

    destroyEventCount = 0
    marker.onDidDestroy -> destroyEventCount++

    marker.destroy()
    expect(destroyEventCount).toBe 1

  it "emits update events when markers are created, updated directly, updated indirectly, or destroyed", ->
    buffer = new TextBuffer(text: 'hello world')
    displayLayer = buffer.addDisplayLayer(tabLength: 4)
    markerLayer = displayLayer.addMarkerLayer()

    updateEventCount = 0
    markerLayer.onDidUpdate -> updateEventCount++

    marker = markerLayer.markScreenRange([[0, 4], [1, 4]])

    waitsFor 'update event', ->
      updateEventCount is 1

    runs ->
      marker.setScreenRange([[0, 5], [1, 0]])

    waitsFor 'update event', ->
      updateEventCount is 2

    runs ->
      buffer.insert([0, 0], '\t')

    waitsFor 'update event', ->
      updateEventCount is 3

    runs ->
      marker.destroy()

    waitsFor 'update event', ->
      updateEventCount is 4

  describe "findMarkers(params)", ->
    [markerLayer, displayLayer] = []

    beforeEach ->
      buffer = new TextBuffer(text: SampleText)
      displayLayer = buffer.addDisplayLayer(tabLength: 4)
      markerLayer = displayLayer.addMarkerLayer()

    it "allows the startBufferRow and endBufferRow to be specified", ->
      marker1 = markerLayer.markBufferRange([[0, 0], [3, 0]], class: 'a')
      marker2 = markerLayer.markBufferRange([[0, 0], [5, 0]], class: 'a')
      marker3 = markerLayer.markBufferRange([[9, 0], [10, 0]], class: 'b')

      expect(markerLayer.findMarkers(class: 'a', startBufferRow: 0)).toEqual [marker2, marker1]
      expect(markerLayer.findMarkers(class: 'a', startBufferRow: 0, endBufferRow: 3)).toEqual [marker1]
      expect(markerLayer.findMarkers(endBufferRow: 10)).toEqual [marker3]

    # TODO: Enable these tests once DisplayLayer supports folding so we actually
    # test row translation fully.
    it "allows the startScreenRow and endScreenRow to be specified", ->
      marker1 = markerLayer.markBufferRange([[6, 0], [7, 0]], class: 'a')
      marker2 = markerLayer.markBufferRange([[9, 0], [10, 0]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', startScreenRow: 6, endScreenRow: 7)).toEqual [marker2]

    it "allows intersectsBufferRowRange to be specified", ->
      marker1 = markerLayer.markBufferRange([[5, 0], [5, 0]], class: 'a')
      marker2 = markerLayer.markBufferRange([[8, 0], [8, 0]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', intersectsBufferRowRange: [5, 6])).toEqual [marker1]

    it "allows intersectsScreenRowRange to be specified", ->
      marker1 = markerLayer.markBufferRange([[5, 0], [5, 0]], class: 'a')
      marker2 = markerLayer.markBufferRange([[8, 0], [8, 0]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', intersectsScreenRowRange: [5, 10])).toEqual [marker2]

    it "allows containedInScreenRange to be specified", ->
      marker1 = markerLayer.markBufferRange([[5, 0], [5, 0]], class: 'a')
      marker2 = markerLayer.markBufferRange([[8, 0], [8, 0]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', containedInScreenRange: [[5, 0], [7, 0]])).toEqual [marker2]

    it "allows intersectsBufferRange to be specified", ->
      marker1 = markerLayer.markBufferRange([[5, 0], [5, 0]], class: 'a')
      marker2 = markerLayer.markBufferRange([[8, 0], [8, 0]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', intersectsBufferRange: [[5, 0], [6, 0]])).toEqual [marker1]

    it "allows intersectsScreenRange to be specified", ->
      marker1 = markerLayer.markBufferRange([[5, 0], [5, 0]], class: 'a')
      marker2 = markerLayer.markBufferRange([[8, 0], [8, 0]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', intersectsScreenRange: [[5, 0], [10, 0]])).toEqual [marker2]
