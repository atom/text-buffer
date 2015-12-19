TextBuffer = require '../src/text-buffer'
Point = require '../src/point'
Range = require '../src/range'

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

  it "emits events when markers are destroyed", ->
    buffer = new TextBuffer(text: 'hello world')
    displayLayer = buffer.addDisplayLayer(tabLength: 4)
    markerLayer = displayLayer.addMarkerLayer()
    marker = markerLayer.markScreenRange([[0, 4], [1, 4]])

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
