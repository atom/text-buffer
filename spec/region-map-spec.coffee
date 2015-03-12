Point = require "../src/point"
RegionMap = require "../src/region-map"

describe "RegionMap", ->
  regionMap = null

  beforeEach ->
    regionMap = new RegionMap

  describe "iterator", ->
    it "terminates immediately when there is no content", ->
      iterator = regionMap[Symbol.iterator]()
      expect(iterator.getPosition()).toEqual(Point.zero())

      expect(iterator.next()).toEqual(value: {extent: Point.infinity(), content: null}, done: false)
      expect(iterator.getPosition()).toEqual(Point.infinity())

      expect(iterator.next()).toEqual(value: null, done: true)
      expect(iterator.getPosition()).toEqual(Point.infinity())

    it "allows new regions to be spliced at the current position", ->
      iterator = regionMap[Symbol.iterator]()

      iterator.seek(Point(0, 2))
      expect(iterator.getPosition()).toEqual(Point(0, 2))

      iterator.splice(Point(0, 5), extent: Point(0, 3), content: "abc")
      expect(iterator.getPosition()).toEqual(Point(0, 5))

      iterator.splice(Point(0, 5), extent: Point(0, 4), content: "defg")
      expect(iterator.getPosition()).toEqual(Point(0, 9))

      expect(iterator.next()).toEqual(value: {extent: Point.infinity(), content: null}, done: false)
      expect(iterator.getPosition()).toEqual(Point.infinity())

      iterator.seek(Point.zero())

      expect(iterator.next()).toEqual(value: {content: null, extent: Point(0, 2)}, done: false)
      expect(iterator.getPosition()).toEqual(Point(0, 2))

      expect(iterator.next()).toEqual(value: {content: "abc", extent: Point(0, 3)}, done: false)
      expect(iterator.getPosition()).toEqual(Point(0, 5))

      expect(iterator.next()).toEqual(value: {content: "defg", extent: Point(0, 4)}, done: false)
      expect(iterator.getPosition()).toEqual(Point(0, 9))

      expect(iterator.next()).toEqual(value: {extent: Point.infinity(), content: null}, done: false)
      expect(iterator.getPosition()).toEqual(Point.infinity())
