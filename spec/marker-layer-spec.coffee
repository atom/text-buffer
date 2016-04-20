{uniq, times} = require 'underscore-plus'
TextBuffer = require '../src/text-buffer'

describe "MarkerLayer", ->
  [buffer, layer1, layer2] = []

  beforeEach ->
    jasmine.addCustomEqualityTester(require("underscore-plus").isEqual)
    buffer = new TextBuffer(text: """
    Lorem ipsum dolor sit amet,
    consectetur adipisicing elit,
    sed do eiusmod tempor incididunt
    ut labore et dolore magna aliqua.
    Ut enim ad minim veniam, quis
    nostrud exercitation ullamco laboris.
    """)
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

  describe "when destroyInvalidatedMarkers is enabled for the layer", ->
    it "destroys markers when they are invalidated via a splice", ->
      layer3 = buffer.addMarkerLayer(destroyInvalidatedMarkers: true)

      marker1 = layer3.markRange([[0, 0], [0, 3]], invalidate: 'inside')
      marker2 = layer3.markRange([[0, 2], [0, 6]], invalidate: 'inside')

      destroyedMarkers = []
      marker1.onDidDestroy -> destroyedMarkers.push(marker1)
      marker2.onDidDestroy -> destroyedMarkers.push(marker2)

      buffer.insert([0, 5], 'x')

      expect(destroyedMarkers).toEqual [marker2]
      expect(marker2.isDestroyed()).toBe true
      expect(marker1.isDestroyed()).toBe false

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
    it "notifies observers synchronously or at the end of a transaction when markers are created, updated, or destroyed", ->
      layer = buffer.addMarkerLayer({maintainHistory: true})
      events = []
      [marker1, marker2, marker3] = []
      layer.onDidUpdate (event) -> events.push(event)

      buffer.transact ->
        marker1 = layer.markRange([[0, 2], [0, 4]])
        marker2 = layer.markRange([[0, 6], [0, 8]])
        expect(events.length).toBe(0)

      marker3 = layer.markRange([[4, 0], [4, 5]])

      expect(events.length).toBe(2)
      expect(Array.from(events[0].created)).toEqual [marker1.id, marker2.id]
      expect(Array.from(events[0].updated)).toEqual []
      expect(Array.from(events[0].destroyed)).toEqual []
      expect(Array.from(events[1].created)).toEqual [marker3.id]
      expect(Array.from(events[1].updated)).toEqual []
      expect(Array.from(events[1].destroyed)).toEqual []

      events = []
      buffer.transact ->
        marker1.setRange([[1, 2], [3, 4]])
        marker2.setRange([[3, 10], [4, 5]])
        marker3.destroy()

      expect(events.length).toBe(1)
      expect(Array.from(events[0].created)).toEqual []
      expect(Array.from(events[0].updated)).toEqual [marker1.id, marker2.id]
      expect(Array.from(events[0].destroyed)).toEqual [marker3.id]

      events = []
      buffer.transact ->
        buffer.insert([1, 3], "xxx")
        buffer.insert([2, 0], "yyy")
      buffer.insert([1, 5], 'zzz')

      expect(events.length).toBe(2)
      expect(Array.from(events[0].created)).toEqual []
      expect(Array.from(events[0].updated)).toEqual [marker1.id]
      expect(Array.from(events[0].destroyed)).toEqual []
      expect(Array.from(events[1].created)).toEqual []
      expect(Array.from(events[1].updated)).toEqual [marker1.id]
      expect(Array.from(events[1].destroyed)).toEqual []

      events = []
      buffer.undo()
      buffer.undo()

      expect(events.length).toBe(2)
      expect(Array.from(events[0].created)).toEqual []
      expect(Array.from(events[0].updated)).toEqual [marker1.id]
      expect(Array.from(events[0].destroyed)).toEqual []
      expect(Array.from(events[1].created)).toEqual []
      expect(Array.from(events[1].updated)).toEqual [marker1.id]
      expect(Array.from(events[1].destroyed)).toEqual []

      events = []
      buffer.transact ->
        buffer.insert([1, 3], 'aaa')
        buffer.insert([3, 11], 'bbb')
        buffer.transact ->
          buffer.insert([1, 9], 'ccc')
          buffer.insert([1, 12], 'ddd')
        buffer.insert([4, 0], 'eee')
        buffer.insert([4, 3], 'fff')

      expect(events.length).toBe(2)
      expect(Array.from(events[0].created)).toEqual []
      expect(Array.from(events[0].updated)).toEqual [marker1.id, marker2.id]
      expect(Array.from(events[0].destroyed)).toEqual []
      expect(Array.from(events[1].created)).toEqual []
      expect(Array.from(events[1].updated)).toEqual [marker2.id]
      expect(Array.from(events[1].destroyed)).toEqual []

      events = []
      buffer.transact ->
        buffer.insert([3, 11], 'ggg')
        buffer.undo()
        marker1.clearTail()
        marker2.clearTail()

      expect(events.length).toBe(2)
      expect(Array.from(events[0].created)).toEqual []
      expect(Array.from(events[0].updated)).toEqual [marker2.id]
      expect(Array.from(events[0].destroyed)).toEqual []
      expect(Array.from(events[1].created)).toEqual []
      expect(Array.from(events[1].updated)).toEqual [marker1.id, marker2.id]
      expect(Array.from(events[1].destroyed)).toEqual []

      events = []
      buffer.transact ->
        marker1.destroy()
        marker2.destroy()

      expect(events.length).toBe(1)
      expect(Array.from(events[0].created)).toEqual []
      expect(Array.from(events[0].updated)).toEqual []
      expect(Array.from(events[0].destroyed)).toEqual [marker1.id, marker2.id]

  describe "::copy", ->
    it "creates a new marker layer with markers in the same states", ->
      originalLayer = buffer.addMarkerLayer(maintainHistory: true)
      originalLayer.markRange([[0, 1], [0, 3]], a: 'b')
      originalLayer.markPosition([0, 2])

      copy = originalLayer.copy()
      expect(copy).not.toBe originalLayer

      markers = copy.getMarkers()
      expect(markers.length).toBe 2
      expect(markers[0].getRange()).toEqual [[0, 1], [0, 3]]
      expect(markers[0].getProperties()).toEqual {a: 'b'}
      expect(markers[1].getRange()).toEqual [[0, 2], [0, 2]]
      expect(markers[1].hasTail()).toBe false
