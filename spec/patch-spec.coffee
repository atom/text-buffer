Point = require "../src/point"
Patch = require "../src/patch"

describe "Patch", ->
  patch = null

  beforeEach ->
    patch = new Patch

  describe "::splice(outputPosition, oldOutputExtent, newOutputExtent, content)", ->
    it "can insert disjoint changes", ->
      patch.splice(Point(0, 5), Point(0, 3), Point(0, 4), "abcd")
      patch.splice(Point(0, 12), Point(0, 4), Point(0, 3), "efg")
      patch.splice(Point(0, 16), Point(0, 3), Point(0, 2), "hi")
      expect(patch.getHunks()).toEqual [
        {
          inputExtent: Point(0, 5)
          outputExtent: Point(0, 5)
          content: null
        }
        {
          inputExtent: Point(0, 3)
          outputExtent: Point(0, 4)
          content: "abcd"
        }
        {
          inputExtent: Point(0, 3)
          outputExtent: Point(0, 3)
          content: null
        }
        {
          inputExtent: Point(0, 4)
          outputExtent: Point(0, 3)
          content: "efg"
        }
        {
          inputExtent: Point(0, 1)
          outputExtent: Point(0, 1)
          content: null
        }
        {
          inputExtent: Point(0, 3)
          outputExtent: Point(0, 2)
          content: "hi"
        }
        {
          inputExtent: Point.infinity()
          outputExtent: Point.infinity()
          content: null
        }
      ]

    it "can insert a change within a change", ->
      patch.splice(Point(0, 3), Point(0, 5), Point(0, 8), "abcdefgh")
      patch.splice(Point(0, 4), Point(0, 2), Point(0, 3), "ijk")
      expect(patch.getHunks()).toEqual [
        {
          inputExtent: Point(0, 3)
          outputExtent: Point(0, 3)
          content: null
        }
        {
          inputExtent: Point(0, 5)
          outputExtent: Point(0, 9)
          content: "aijkdefgh"
        }
        {
          inputExtent: Point.infinity()
          outputExtent: Point.infinity()
          content: null
        }
      ]

      patch.splice(Point(0, 4), Point(0, 3), Point(0, 1), "l")
      expect(patch.getHunks()).toEqual [
        {
          inputExtent: Point(0, 3)
          outputExtent: Point(0, 3)
          content: null
        }
        {
          inputExtent: Point(0, 5)
          outputExtent: Point(0, 7)
          content: "aldefgh"
        }
        {
          inputExtent: Point.infinity()
          outputExtent: Point.infinity()
          content: null
        }
      ]

    it "can insert a change that overlaps the end of an existing change", ->
      patch.splice(Point(0, 5), Point(0, 3), Point(0, 4), "abcd")
      patch.splice(Point(0, 8), Point(0, 4), Point(0, 5), "efghi")
      expect(patch.getHunks()).toEqual [
        {
          inputExtent: Point(0, 5)
          outputExtent: Point(0, 5)
          content: null
        }
        {
          inputExtent: Point(0, 6)
          outputExtent: Point(0, 8)
          content: "abcefghi"
        }
        {
          inputExtent: Point.infinity()
          outputExtent: Point.infinity()
          content: null
        }
      ]

      patch.splice(Point(0, 9), Point(0, 6), Point(0, 3), "jkl")
      expect(patch.getHunks()).toEqual [
        {
          inputExtent: Point(0, 5)
          outputExtent: Point(0, 5)
          content: null
        }
        {
          inputExtent: Point(0, 8)
          outputExtent: Point(0, 7)
          content: "abcejkl"
        }
        {
          inputExtent: Point.infinity()
          outputExtent: Point.infinity()
          content: null
        }
      ]
