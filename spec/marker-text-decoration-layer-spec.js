const SAMPLE_TEXT = require('./helpers/sample-text')
const MarkerTextDecorationLayer = require('../src/marker-text-decoration-layer')
const Point = require('../src/point')
const Range = require('../src/range')
const TextBuffer = require('../src/text-buffer')

describe('MarkerTextDecorationLayer', () => {
  describe('iterator', () => {
    it('reports scope ids containing the sought position and can be advanced to retrieve opening and closing scope ids at each boundary', () => {
      const buffer = new TextBuffer({text: SAMPLE_TEXT})
      const markerLayer = buffer.addMarkerLayer()
      markerLayer.markPosition([0, 3])
      const marker2 = markerLayer.markRange([[0, 2], [1, 4]])
      const marker3 = markerLayer.markRange([[0, 4], [1, 4]])
      const marker4 = markerLayer.markRange([[0, 4], [2, 3]])

      const textDecorationLayer = new MarkerTextDecorationLayer(markerLayer, {
        classNameForMarkerId: () => 'foo'
      })
      const iterator = textDecorationLayer.buildIterator()
      expect(iterator.seek(Point(0, 3))).toEqual([marker2.id])
      expect(iterator.getPosition()).toEqual(Point(0, 4))
      expect(iterator.getCloseScopeIds()).toEqual([])
      expect(iterator.getOpenScopeIds()).toEqual([marker3.id, marker4.id])

      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(1, 4))
      expect(iterator.getCloseScopeIds()).toEqual([marker2.id, marker3.id])
      expect(iterator.getOpenScopeIds()).toEqual([])

      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(2, 3))
      expect(iterator.getCloseScopeIds()).toEqual([marker4.id])
      expect(iterator.getOpenScopeIds()).toEqual([])

      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point.INFINITY)
      expect(iterator.getCloseScopeIds()).toEqual([])
      expect(iterator.getOpenScopeIds()).toEqual([])

      expect(iterator.seek(Point(1, 0))).toEqual([marker2.id, marker4.id, marker3.id])
      expect(iterator.getPosition()).toEqual(Point(1, 4))
      expect(iterator.getCloseScopeIds()).toEqual([marker2.id, marker3.id])
      expect(iterator.getOpenScopeIds()).toEqual([])

      expect(iterator.seek(Point(5, 0))).toEqual([])
      expect(iterator.getPosition()).toEqual(Point.INFINITY)
      expect(iterator.getCloseScopeIds()).toEqual([])
      expect(iterator.getOpenScopeIds()).toEqual([])
    })

    it('does not report scope ids that are associated to invalidated markers', () => {
      const buffer = new TextBuffer({text: SAMPLE_TEXT})
      const markerLayer = buffer.addMarkerLayer()
      const marker1 = markerLayer.markRange([[0, 2], [1, 4]], {invalidate: 'touch'})
      buffer.insert([0, 2], '+')
      expect(marker1.isValid()).toBe(false)
      const marker2 = markerLayer.markRange([[0, 4], [2, 3]])

      const textDecorationLayer = new MarkerTextDecorationLayer(markerLayer, {
        classNameForMarkerId: () => 'foo'
      })
      const iterator = textDecorationLayer.buildIterator()
      expect(iterator.seek(Point(0, 5))).toEqual([marker2.id])
      expect(iterator.getPosition()).toEqual(Point(2, 3))
      expect(iterator.getCloseScopeIds()).toEqual([marker2.id])
      expect(iterator.getOpenScopeIds()).toEqual([])

      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point.INFINITY)
      expect(iterator.getCloseScopeIds()).toEqual([])
      expect(iterator.getOpenScopeIds()).toEqual([])
    })

    it('does not report boundaries that are not associated with the start/end of a decorated marker', () => {
      const buffer = new TextBuffer({text: SAMPLE_TEXT})
      const markerLayer = buffer.addMarkerLayer()
      const marker1 = markerLayer.markRange([[0, 1], [0, 3]])
      const marker2 = markerLayer.markRange([[0, 2], [0, 5]])
      const marker3 = markerLayer.markRange([[0, 5], [0, 7]])
      const marker4 = markerLayer.markRange([[0, 9], [0, 12]])
      const textDecorationLayer = new MarkerTextDecorationLayer(markerLayer, {
        classNameForMarkerId: (markerId) => {
          if (marker2.id === markerId) return 'foo'
        },
        inlineStyleForMarkerId: (markerId) => {
          if (marker4.id === markerId) return {color: 'bar'}
        }
      })

      const iterator = textDecorationLayer.buildIterator()
      expect(iterator.seek(Point(0, 3))).toEqual([marker2.id])
      expect(iterator.getPosition()).toEqual(Point(0, 5))
      expect(iterator.getCloseScopeIds()).toEqual([marker2.id])
      expect(iterator.getOpenScopeIds()).toEqual([])

      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(0, 9))
      expect(iterator.getCloseScopeIds()).toEqual([])
      expect(iterator.getOpenScopeIds()).toEqual([marker4.id])
    })

    it('fetches boundaries as needed based on the boundariesPerQuery parameter', () => {
      const buffer = new TextBuffer({text: 'abcdef\n'.repeat(20)})
      const markerLayer = buffer.addMarkerLayer()
      const marker1 = markerLayer.markRange([[0, 2], [1, 2]])
      const marker2 = markerLayer.markRange([[2, 2], [3, 2]])
      const marker3 = markerLayer.markRange([[3, 2], [4, 2]])
      const marker4 = markerLayer.markRange([[10, 2], [11, 2]])
      const marker5 = markerLayer.markRange([[12, 2], [13, 2]])

      const decoratedMarkerIds = new Set([marker1.id, marker2.id, marker3.id, marker4.id, marker5.id])
      const textDecorationLayer = new MarkerTextDecorationLayer(markerLayer, {
        boundariesPerQuery: 3,
        classNameForMarkerId: (markerId) => decoratedMarkerIds.has(markerId) ? 'foo' : null
      })

      const iterator = textDecorationLayer.buildIterator()
      iterator.seek(Point(0, 0))
      expect(iterator.getPosition()).toEqual(Point(0, 2))
      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(1, 2))
      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(2, 2))
      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(3, 2))
      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(4, 2))
      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(10, 2))
      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(11, 2))
      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(12, 2))
      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(13, 2))

      // Ensure skipping more empty boundaries than the size of the query works correctly.
      decoratedMarkerIds.delete(marker1.id)
      decoratedMarkerIds.delete(marker2.id)
      iterator.seek(Point(0, 0))
      expect(iterator.getPosition()).toEqual(Point(3, 2))
      iterator.moveToSuccessor()
      expect(iterator.getPosition()).toEqual(Point(4, 2))
    })
  })

  it('emits invalidation range events when a marker is added, destroyed or updated manually', () => {
    const buffer = new TextBuffer({text: SAMPLE_TEXT})
    const markerLayer = buffer.addMarkerLayer()
    const marker1 = markerLayer.markRange([[0, 3], [1, 4]])
    const textDecorationLayer = new MarkerTextDecorationLayer(markerLayer, {})
    let rangeInvalidationEvents
    textDecorationLayer.onDidInvalidateRange((range) => rangeInvalidationEvents.push(range))

    rangeInvalidationEvents = []
    const marker2 = markerLayer.markRange(Range(Point(2, 4), Point(3, 6)))
    expect(textDecorationLayer.getInvalidatedRanges()).toEqual([])
    expect(rangeInvalidationEvents).toEqual([
      Range(Point(2, 4), Point(3, 6))
    ])

    rangeInvalidationEvents = []
    buffer.insert([0, 1], '123')
    expect(textDecorationLayer.getInvalidatedRanges()).toEqual([])
    expect(rangeInvalidationEvents).toEqual([])

    rangeInvalidationEvents = []
    marker1.destroy()
    expect(textDecorationLayer.getInvalidatedRanges()).toEqual([])
    expect(rangeInvalidationEvents).toEqual([
      Range(Point(0, 6), Point(1, 4))
    ])

    rangeInvalidationEvents = []
    marker2.setRange(Range(Point(0, 1), Point(2, 7)))
    expect(textDecorationLayer.getInvalidatedRanges()).toEqual([])
    expect(rangeInvalidationEvents).toEqual([
      Range(Point(2, 4), Point(3, 6)),
      Range(Point(0, 1), Point(2, 7))
    ])

    rangeInvalidationEvents = []
    buffer.setTextInRange([[0, 0], [1, 3]], '---')
    expect(textDecorationLayer.getInvalidatedRanges()).toEqual([
      Range(Point(0, 3), Point(1, 7))
    ])
    expect(rangeInvalidationEvents).toEqual([])
    textDecorationLayer.clearInvalidatedRanges()
    expect(textDecorationLayer.getInvalidatedRanges()).toEqual([])

    rangeInvalidationEvents = []
    textDecorationLayer.destroy()
    marker2.setRange(Range(Point(2, 1), Point(2, 7)))
    expect(textDecorationLayer.getInvalidatedRanges()).toEqual([])
    expect(rangeInvalidationEvents).toEqual([])
  })
})