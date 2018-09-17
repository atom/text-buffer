TextBuffer = require '../src/text-buffer'
Point = require '../src/point'
Range = require '../src/range'
SampleText = require './helpers/sample-text'

describe "DisplayMarkerLayer", ->
  beforeEach ->
    jasmine.addCustomEqualityTester(require("underscore-plus").isEqual)

  it "allows DisplayMarkers to be created and manipulated in screen coordinates", ->
    buffer = new TextBuffer(text: 'abc\ndef\nghi\nj\tk\tl\nmno')
    displayLayer = buffer.addDisplayLayer(tabLength: 4)
    markerLayer = displayLayer.addMarkerLayer()

    marker = markerLayer.markScreenRange([[3, 4], [4, 2]])
    expect(marker.getScreenRange()).toEqual [[3, 4], [4, 2]]
    expect(marker.getBufferRange()).toEqual [[3, 2], [4, 2]]

    markerChangeEvents = []
    marker.onDidChange (change) -> markerChangeEvents.push(change)

    marker.setScreenRange([[3, 8], [4, 3]])

    expect(marker.getBufferRange()).toEqual([[3, 4], [4, 3]])
    expect(marker.getScreenRange()).toEqual([[3, 8], [4, 3]])
    expect(markerChangeEvents[0]).toEqual {
      oldHeadBufferPosition: [4, 2]
      newHeadBufferPosition: [4, 3]
      oldTailBufferPosition: [3, 2]
      newTailBufferPosition: [3, 4]
      oldHeadScreenPosition: [4, 2]
      newHeadScreenPosition: [4, 3]
      oldTailScreenPosition: [3, 4]
      newTailScreenPosition: [3, 8]
      wasValid: true
      isValid: true
      textChanged: false
    }

    markerChangeEvents = []
    buffer.insert([4, 0], '\t')

    expect(marker.getBufferRange()).toEqual([[3, 4], [4, 4]])
    expect(marker.getScreenRange()).toEqual([[3, 8], [4, 7]])
    expect(markerChangeEvents[0]).toEqual {
      oldHeadBufferPosition: [4, 3]
      newHeadBufferPosition: [4, 4]
      oldTailBufferPosition: [3, 4]
      newTailBufferPosition: [3, 4]
      oldHeadScreenPosition: [4, 3]
      newHeadScreenPosition: [4, 7]
      oldTailScreenPosition: [3, 8]
      newTailScreenPosition: [3, 8]
      wasValid: true
      isValid: true
      textChanged: true
    }

    expect(markerLayer.getMarker(marker.id)).toBe marker

    markerChangeEvents = []
    foldId = displayLayer.foldBufferRange([[0, 2], [2, 2]])

    expect(marker.getBufferRange()).toEqual([[3, 4], [4, 4]])
    expect(marker.getScreenRange()).toEqual([[1, 8], [2, 7]])
    expect(markerChangeEvents[0]).toEqual {
      oldHeadBufferPosition: [4, 4]
      newHeadBufferPosition: [4, 4]
      oldTailBufferPosition: [3, 4]
      newTailBufferPosition: [3, 4]
      oldHeadScreenPosition: [4, 7]
      newHeadScreenPosition: [2, 7]
      oldTailScreenPosition: [3, 8]
      newTailScreenPosition: [1, 8]
      wasValid: true
      isValid: true
      textChanged: false
    }

    markerChangeEvents = []
    displayLayer.destroyFold(foldId)

    expect(marker.getBufferRange()).toEqual([[3, 4], [4, 4]])
    expect(marker.getScreenRange()).toEqual([[3, 8], [4, 7]])
    expect(markerChangeEvents[0]).toEqual {
      oldHeadBufferPosition: [4, 4]
      newHeadBufferPosition: [4, 4]
      oldTailBufferPosition: [3, 4]
      newTailBufferPosition: [3, 4]
      oldHeadScreenPosition: [2, 7]
      newHeadScreenPosition: [4, 7]
      oldTailScreenPosition: [1, 8]
      newTailScreenPosition: [3, 8]
      wasValid: true
      isValid: true
      textChanged: false
    }

    markerChangeEvents = []
    displayLayer.reset({tabLength: 3})

    expect(marker.getBufferRange()).toEqual([[3, 4], [4, 4]])
    expect(marker.getScreenRange()).toEqual([[3, 6], [4, 6]])
    expect(markerChangeEvents[0]).toEqual {
      oldHeadBufferPosition: [4, 4]
      newHeadBufferPosition: [4, 4]
      oldTailBufferPosition: [3, 4]
      newTailBufferPosition: [3, 4]
      oldHeadScreenPosition: [4, 7]
      newHeadScreenPosition: [4, 6]
      oldTailScreenPosition: [3, 8]
      newTailScreenPosition: [3, 6]
      wasValid: true
      isValid: true
      textChanged: false
    }

  it "does not create duplicate DisplayMarkers when it has onDidCreateMarker observers (regression)", ->
    buffer = new TextBuffer(text: 'abc\ndef\nghi\nj\tk\tl\nmno')
    displayLayer = buffer.addDisplayLayer(tabLength: 4)
    markerLayer = displayLayer.addMarkerLayer()

    emittedMarker = null
    markerLayer.onDidCreateMarker (marker) ->
      emittedMarker = marker

    createdMarker = markerLayer.markBufferRange([[0, 1], [2, 3]])
    expect(createdMarker).toBe(emittedMarker)

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

  it "emits update events when markers are created, updated directly, updated indirectly, or destroyed", (done) ->
    buffer = new TextBuffer(text: 'hello world')
    displayLayer = buffer.addDisplayLayer(tabLength: 4)
    markerLayer = displayLayer.addMarkerLayer()
    marker = null

    updateEventCount = 0
    markerLayer.onDidUpdate ->
      updateEventCount++
      if updateEventCount is 1
        marker.setScreenRange([[0, 5], [1, 0]])
      else if updateEventCount is 2
        buffer.insert([0, 0], '\t')
      else if updateEventCount is 3
        marker.destroy()
      else if updateEventCount is 4
        done()

    buffer.transact ->
      marker = markerLayer.markScreenRange([[0, 4], [1, 4]])

  it "allows markers to be copied", ->
    buffer = new TextBuffer(text: '\ta\tbc\tdef\tg\n\th')
    displayLayer = buffer.addDisplayLayer(tabLength: 4)
    markerLayer = displayLayer.addMarkerLayer()

    markerA = markerLayer.markScreenRange([[0, 4], [1, 4]], a: 1, b: 2)
    markerB = markerA.copy(b: 3, c: 4)

    expect(markerB.id).not.toBe(markerA.id)
    expect(markerB.getProperties()).toEqual({a: 1, b: 3, c: 4})
    expect(markerB.getScreenRange()).toEqual(markerA.getScreenRange())

  describe "::destroy()", ->
    it "only destroys the underlying buffer MarkerLayer if the DisplayMarkerLayer was created by calling addMarkerLayer on its parent DisplayLayer", ->
      buffer = new TextBuffer(text: 'abc\ndef\nghi\nj\tk\tl\nmno')
      displayLayer1 = buffer.addDisplayLayer(tabLength: 2)
      displayLayer2 = buffer.addDisplayLayer(tabLength: 4)
      bufferMarkerLayer = buffer.addMarkerLayer()
      bufferMarker1 = bufferMarkerLayer.markRange [[2, 1], [2, 2]]
      displayMarkerLayer1 = displayLayer1.getMarkerLayer(bufferMarkerLayer.id)
      displayMarker1 = displayMarkerLayer1.markBufferRange [[1, 0], [1, 2]]
      displayMarkerLayer2 = displayLayer2.getMarkerLayer(bufferMarkerLayer.id)
      displayMarker2 = displayMarkerLayer2.markBufferRange [[2, 0], [2, 1]]
      displayMarkerLayer3 = displayLayer2.addMarkerLayer()
      displayMarker3 = displayMarkerLayer3.markBufferRange [[0, 0], [0, 0]]

      displayMarkerLayer1DestroyEventCount = 0
      displayMarkerLayer1.onDidDestroy -> displayMarkerLayer1DestroyEventCount++
      displayMarkerLayer2DestroyEventCount = 0
      displayMarkerLayer2.onDidDestroy -> displayMarkerLayer2DestroyEventCount++
      displayMarkerLayer3DestroyEventCount = 0
      displayMarkerLayer3.onDidDestroy -> displayMarkerLayer3DestroyEventCount++

      displayMarkerLayer1.destroy()
      expect(bufferMarkerLayer.isDestroyed()).toBe(false)
      expect(displayMarkerLayer1.isDestroyed()).toBe(true)
      expect(displayMarkerLayer1DestroyEventCount).toBe(1)
      expect(bufferMarker1.isDestroyed()).toBe(false)
      expect(displayMarker1.isDestroyed()).toBe(true)
      expect(displayMarker2.isDestroyed()).toBe(false)
      expect(displayMarker3.isDestroyed()).toBe(false)

      displayMarkerLayer2.destroy()
      expect(bufferMarkerLayer.isDestroyed()).toBe(false)
      expect(displayMarkerLayer2.isDestroyed()).toBe(true)
      expect(displayMarkerLayer2DestroyEventCount).toBe(1)
      expect(bufferMarker1.isDestroyed()).toBe(false)
      expect(displayMarker1.isDestroyed()).toBe(true)
      expect(displayMarker2.isDestroyed()).toBe(true)
      expect(displayMarker3.isDestroyed()).toBe(false)

      bufferMarkerLayer.destroy()
      expect(bufferMarkerLayer.isDestroyed()).toBe(true)
      expect(displayMarkerLayer1DestroyEventCount).toBe(1)
      expect(displayMarkerLayer2DestroyEventCount).toBe(1)
      expect(bufferMarker1.isDestroyed()).toBe(true)
      expect(displayMarker1.isDestroyed()).toBe(true)
      expect(displayMarker2.isDestroyed()).toBe(true)
      expect(displayMarker3.isDestroyed()).toBe(false)

      displayMarkerLayer3.destroy()
      expect(displayMarkerLayer3.bufferMarkerLayer.isDestroyed()).toBe(true)
      expect(displayMarkerLayer3.isDestroyed()).toBe(true)
      expect(displayMarkerLayer3DestroyEventCount).toBe(1)
      expect(displayMarker3.isDestroyed()).toBe(true)

    it "destroys the layer's markers", ->
      buffer = new TextBuffer()
      displayLayer = buffer.addDisplayLayer()
      displayMarkerLayer = displayLayer.addMarkerLayer()

      marker1 = displayMarkerLayer.markBufferRange([[0, 0], [0, 0]])
      marker2 = displayMarkerLayer.markBufferRange([[0, 0], [0, 0]])

      destroyListener = jasmine.createSpy('onDidDestroy listener')
      marker1.onDidDestroy(destroyListener)

      displayMarkerLayer.destroy()

      expect(destroyListener).toHaveBeenCalled()
      expect(marker1.isDestroyed()).toBe(true)

      # Markers states are updated regardless of whether they have an
      # ::onDidDestroy listener
      expect(marker2.isDestroyed()).toBe(true)

  it "destroys display markers when their underlying buffer markers are destroyed", ->
    buffer = new TextBuffer(text: '\tabc')
    displayLayer1 = buffer.addDisplayLayer(tabLength: 2)
    displayLayer2 = buffer.addDisplayLayer(tabLength: 4)
    bufferMarkerLayer = buffer.addMarkerLayer()
    displayMarkerLayer1 = displayLayer1.getMarkerLayer(bufferMarkerLayer.id)
    displayMarkerLayer2 = displayLayer2.getMarkerLayer(bufferMarkerLayer.id)

    bufferMarker = bufferMarkerLayer.markRange([[0, 1], [0, 2]])

    displayMarker1 = displayMarkerLayer1.getMarker(bufferMarker.id)
    displayMarker2 = displayMarkerLayer2.getMarker(bufferMarker.id)
    expect(displayMarker1.getScreenRange()).toEqual([[0, 2], [0, 3]])
    expect(displayMarker2.getScreenRange()).toEqual([[0, 4], [0, 5]])

    displayMarker1DestroyCount = 0
    displayMarker2DestroyCount = 0
    displayMarker1.onDidDestroy -> displayMarker1DestroyCount++
    displayMarker2.onDidDestroy -> displayMarker2DestroyCount++

    bufferMarker.destroy()
    expect(displayMarker1DestroyCount).toBe(1)
    expect(displayMarker2DestroyCount).toBe(1)

  it "does not throw exceptions when buffer markers are destroyed that don't have corresponding display markers", ->
    buffer = new TextBuffer(text: '\tabc')
    displayLayer1 = buffer.addDisplayLayer(tabLength: 2)
    displayLayer2 = buffer.addDisplayLayer(tabLength: 4)
    bufferMarkerLayer = buffer.addMarkerLayer()
    displayMarkerLayer1 = displayLayer1.getMarkerLayer(bufferMarkerLayer.id)
    displayMarkerLayer2 = displayLayer2.getMarkerLayer(bufferMarkerLayer.id)

    bufferMarker = bufferMarkerLayer.markRange([[0, 1], [0, 2]])
    bufferMarker.destroy()

  it "destroys itself when the underlying buffer marker layer is destroyed", ->
    buffer = new TextBuffer(text: 'abc\ndef\nghi\nj\tk\tl\nmno')
    displayLayer1 = buffer.addDisplayLayer(tabLength: 2)
    displayLayer2 = buffer.addDisplayLayer(tabLength: 4)

    bufferMarkerLayer = buffer.addMarkerLayer()
    displayMarkerLayer1 = displayLayer1.getMarkerLayer(bufferMarkerLayer.id)
    displayMarkerLayer2 = displayLayer2.getMarkerLayer(bufferMarkerLayer.id)
    displayMarkerLayer1DestroyEventCount = 0
    displayMarkerLayer1.onDidDestroy -> displayMarkerLayer1DestroyEventCount++
    displayMarkerLayer2DestroyEventCount = 0
    displayMarkerLayer2.onDidDestroy -> displayMarkerLayer2DestroyEventCount++

    bufferMarkerLayer.destroy()
    expect(displayMarkerLayer1.isDestroyed()).toBe(true)
    expect(displayMarkerLayer1DestroyEventCount).toBe(1)
    expect(displayMarkerLayer2.isDestroyed()).toBe(true)
    expect(displayMarkerLayer2DestroyEventCount).toBe(1)

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

    it "allows the startScreenRow and endScreenRow to be specified", ->
      marker1 = markerLayer.markBufferRange([[6, 0], [7, 0]], class: 'a')
      marker2 = markerLayer.markBufferRange([[9, 0], [10, 0]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', startScreenRow: 6, endScreenRow: 7)).toEqual [marker2]

      displayLayer.destroyFoldsIntersectingBufferRange([[4, 0], [7, 0]])
      displayLayer.foldBufferRange([[0, 20], [12, 2]])
      marker3 = markerLayer.markBufferRange([[12, 0], [12, 0]], class: 'a')
      expect(markerLayer.findMarkers(class: 'a', startScreenRow: 0)).toEqual [marker1, marker2, marker3]
      expect(markerLayer.findMarkers(class: 'a', endScreenRow: 0)).toEqual [marker1, marker2, marker3]

    it "allows the startsInBufferRange/endsInBufferRange and startsInScreenRange/endsInScreenRange to be specified", ->
      marker1 = markerLayer.markBufferRange([[5, 2], [5, 4]], class: 'a')
      marker2 = markerLayer.markBufferRange([[8, 0], [8, 2]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', startsInBufferRange: [[5, 1], [5, 3]])).toEqual [marker1]
      expect(markerLayer.findMarkers(class: 'a', endsInBufferRange: [[8, 1], [8, 3]])).toEqual [marker2]
      expect(markerLayer.findMarkers(class: 'a', startsInScreenRange: [[4, 0], [4, 1]])).toEqual [marker1]
      expect(markerLayer.findMarkers(class: 'a', endsInScreenRange: [[5, 1], [5, 3]])).toEqual [marker2]

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

      displayLayer.destroyAllFolds()
      displayLayer.foldBufferRange([[0, 20], [12, 2]])
      expect(markerLayer.findMarkers(class: 'a', intersectsScreenRowRange: [0, 0])).toEqual [marker1, marker2]

      displayLayer.destroyAllFolds()
      displayLayer.reset({softWrapColumn: 10})
      marker1.setHeadScreenPosition([6, 5])
      marker2.setHeadScreenPosition([9, 2])
      expect(markerLayer.findMarkers(class: 'a', intersectsScreenRowRange: [5, 7])).toEqual [marker1]

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

    it "allows containsBufferPosition to be specified", ->
      marker1 = markerLayer.markBufferRange([[5, 0], [5, 0]], class: 'a')
      marker2 = markerLayer.markBufferRange([[8, 0], [8, 0]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', containsBufferPosition: [8, 0])).toEqual [marker2]

    it "allows containsScreenPosition to be specified", ->
      marker1 = markerLayer.markBufferRange([[5, 0], [5, 0]], class: 'a')
      marker2 = markerLayer.markBufferRange([[8, 0], [8, 0]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', containsScreenPosition: [5, 0])).toEqual [marker2]

    it "allows containsBufferRange to be specified", ->
      marker1 = markerLayer.markBufferRange([[5, 0], [5, 10]], class: 'a')
      marker2 = markerLayer.markBufferRange([[8, 0], [8, 10]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', containsBufferRange: [[8, 2], [8, 4]])).toEqual [marker2]

    it "allows containsScreenRange to be specified", ->
      marker1 = markerLayer.markBufferRange([[5, 0], [5, 10]], class: 'a')
      marker2 = markerLayer.markBufferRange([[8, 0], [8, 10]], class: 'a')
      displayLayer.foldBufferRange([[4, 0], [7, 0]])
      expect(markerLayer.findMarkers(class: 'a', containsScreenRange: [[5, 2], [5, 4]])).toEqual [marker2]

    it "works when used from within a Marker.onDidDestroy callback (regression)", ->
      displayMarker = markerLayer.markBufferRange([[0, 3], [0, 6]])
      displayMarker.onDidDestroy ->
        expect(markerLayer.findMarkers({containsBufferPosition: [0, 4]})).not.toContain(displayMarker)
      displayMarker.destroy()
