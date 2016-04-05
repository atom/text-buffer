{uniq, times} = require 'underscore-plus'
TextBuffer = require '../src/text-buffer'

describe "MarkerLayer", ->
  [buffer, layer1, layer2] = []

  beforeEach ->
    jasmine.addCustomEqualityTester(require("underscore-plus").isEqual)
    buffer = new TextBuffer(text: "abcdefghijklmnopqrstuvwxyz")
    layer1 = buffer.addMarkerLayer()
    layer2 = buffer.addMarkerLayer()

  it "ensures that marker ids are unique across layers", ->
    times 5, ->
      buffer.markRange([[0, 3], [0, 6]])
      layer1.markRange([[0, 4], [0, 7]])
      layer2.markRange([[0, 5], [0, 8]])

    ids = buffer.getMarkers()
      .concat(layer1.getMarkers())
      .concat(layer2.getMarkers())
      .map (marker) -> marker.id

    expect(uniq(ids).length).toEqual ids.length

  it "updates each layer's markers when the text changes", ->
    defaultMarker = buffer.markRange([[0, 3], [0, 6]])
    layer1Marker = layer1.markRange([[0, 4], [0, 7]])
    layer2Marker = layer2.markRange([[0, 5], [0, 8]])

    buffer.setTextInRange([[0, 1], [0, 2]], "BBB")
    expect(defaultMarker.getRange()).toEqual [[0, 5], [0, 8]]
    expect(layer1Marker.getRange()).toEqual [[0, 6], [0, 9]]
    expect(layer2Marker.getRange()).toEqual [[0, 7], [0, 10]]

    layer2.destroy()
    expect(layer2.isAlive()).toBe false
    expect(layer2.isDestroyed()).toBe true

    expect(layer1.isAlive()).toBe true
    expect(layer1.isDestroyed()).toBe false

    buffer.undo()
    expect(defaultMarker.getRange()).toEqual [[0, 3], [0, 6]]
    expect(layer1Marker.getRange()).toEqual [[0, 4], [0, 7]]
    expect(layer2Marker.getRange()).toEqual [[0, 7], [0, 10]]

  it "emits onDidCreateMarker events synchronously when markers are created", ->
    createdMarkers = []
    layer1.onDidCreateMarker (marker) -> createdMarkers.push(marker)
    marker = layer1.markRange([[0, 1], [2, 3]])
    expect(createdMarkers).toEqual [marker]

  it "does not emit marker events on the TextBuffer for non-default layers", ->
    createEventCount = updateEventCount = 0
    buffer.onDidCreateMarker -> createEventCount++
    buffer.onDidUpdateMarkers -> updateEventCount++

    marker1 = buffer.markRange([[0, 1], [0, 2]])
    marker1.setRange([[0, 1], [0, 3]])

    expect(createEventCount).toBe 1
    expect(updateEventCount).toBe 2

    marker2 = layer1.markRange([[0, 1], [0, 2]])
    marker2.setRange([[0, 1], [0, 3]])

    expect(createEventCount).toBe 1
    expect(updateEventCount).toBe 2

  describe "when maintainHistory is enabled for the layer", ->
    layer3 = null

    beforeEach ->
      layer3 = buffer.addMarkerLayer(maintainHistory: true)

    it "restores the state of all markers in the layer on undo and redo", ->
      buffer.setText('')
      buffer.transact -> buffer.append('foo')
      layer3 = buffer.addMarkerLayer(maintainHistory: true)

      marker1 = layer3.markRange([[0, 0], [0, 0]], a: 'b', invalidate: 'never')
      marker2 = layer3.markRange([[0, 0], [0, 0]], c: 'd', invalidate: 'never')

      buffer.transact ->
        buffer.append('\n')
        buffer.append('bar')

        marker1.destroy()
        marker2.setRange([[0, 2], [0, 3]])
        marker3 = layer3.markRange([[0, 0], [0, 3]], e: 'f', invalidate: 'never')
        marker4 = layer3.markRange([[1, 0], [1, 3]], g: 'h', invalidate: 'never')

      buffer.undo()

      expect(buffer.getText()).toBe 'foo'
      markers = layer3.findMarkers({})
      expect(markers.length).toBe 2
      expect(markers[0].getProperties()).toEqual {c: 'd'}
      expect(markers[0].getRange()).toEqual [[0, 0], [0, 0]]
      expect(markers[1].getProperties()).toEqual {a: 'b'}
      expect(markers[1].getRange()).toEqual [[0, 0], [0, 0]]

      buffer.redo()

      expect(buffer.getText()).toBe 'foo\nbar'
      markers = layer3.findMarkers({})
      expect(markers.length).toBe 3
      expect(markers[0].getProperties()).toEqual {e: 'f'}
      expect(markers[0].getRange()).toEqual [[0, 0], [0, 3]]
      expect(markers[1].getProperties()).toEqual {c: 'd'}
      expect(markers[1].getRange()).toEqual [[0, 2], [0, 3]]
      expect(markers[2].getProperties()).toEqual {g: 'h'}
      expect(markers[2].getRange()).toEqual [[1, 0], [1, 3]]

    it "does not undo marker manipulations that aren't associated with text changes", ->
      marker = layer3.markRange([[0, 6], [0, 9]])

      # Can't undo changes in a transaction without other buffer changes
      buffer.transact -> marker.setRange([[0, 4], [0, 20]])
      buffer.undo()
      expect(marker.getRange()).toEqual [[0, 4], [0, 20]]

      # Can undo changes in a transaction with other buffer changes
      buffer.transact ->
        marker.setRange([[0, 5], [0, 9]])
        buffer.setTextInRange([[0, 2], [0, 3]], 'XYZ')
        marker.setRange([[0, 8], [0, 12]])

      buffer.undo()
      expect(marker.getRange()).toEqual [[0, 4], [0, 20]]

      buffer.redo()
      expect(marker.getRange()).toEqual [[0, 8], [0, 12]]

    it "ignores snapshot references to marker layers that no longer exist", ->
      layer3.markRange([[0, 6], [0, 9]])
      buffer.append("stuff")
      layer3.destroy()

      # Should not throw an exception
      buffer.undo()

  describe "::findMarkers(params)", ->
    it "does not find markers from other layers", ->
      defaultMarker = buffer.markRange([[0, 3], [0, 6]])
      layer1Marker = layer1.markRange([[0, 3], [0, 6]])
      layer2Marker = layer2.markRange([[0, 3], [0, 6]])

      expect(buffer.findMarkers(containsPoint: [0, 4])).toEqual [defaultMarker]
      expect(layer1.findMarkers(containsPoint: [0, 4])).toEqual [layer1Marker]
      expect(layer2.findMarkers(containsPoint: [0, 4])).toEqual [layer2Marker]

  describe "::onDidUpdate", ->
    it "notifies observers asynchronously when markers are created, updated, or destroyed", (done) ->
      updateCount = 0
      layer1.onDidUpdate ->
        updateCount++
        if updateCount is 1
          marker1.setRange([[1, 2], [3, 4]])
          marker2.setRange([[4, 5], [6, 7]])
        else if updateCount is 2
          buffer.insert([0, 1], "xxx")
          buffer.insert([0, 1], "yyy")
        else if updateCount is 3
          marker1.destroy()
          marker2.destroy()
        else if updateCount is 4
          done()

      marker1 = layer1.markRange([[0, 2], [0, 4]])
      marker2 = layer1.markRange([[0, 6], [0, 8]])

  describe "::copy", ->
    it "creates a new marker layer with markers in the same states", ->
      originalLayer = buffer.addMarkerLayer(maintainHistory: true)
      originalLayer.markRange([[0, 1], [0, 3]], a: 'b')
      originalLayer.markPosition([0, 2], c: 'd')

      copy = originalLayer.copy()
      expect(copy).not.toBe originalLayer

      markers = copy.getMarkers()
      expect(markers.length).toBe 2
      expect(markers[0].getRange()).toEqual [[0, 1], [0, 3]]
      expect(markers[0].getProperties()).toEqual {a: 'b'}
      expect(markers[1].getRange()).toEqual [[0, 2], [0, 2]]
      expect(markers[1].getProperties()).toEqual {c: 'd'}
      expect(markers[1].hasTail()).toBe false
