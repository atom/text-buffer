Point = require "../src/point"

describe "Point", ->
  describe "::fromObject(object, copy)", ->
    it "returns a new Point if object is point-compatible array ", ->
      expect(Point.fromObject([1, 3]).isEqual(Point(1, 3)))
      expect(Point.fromObject([Infinity, Infinity]).isEqual(Point.infinity()))

    it "returns the copy of object if it is an instanceof Point", ->
      origin = Point(0, 0)
      expect(Point.fromObject(origin, false) is origin).toBe true
      expect(Point.fromObject(origin, true) is origin).toBe false

  describe "::isEqual()", ->
    it "returns if whether two points are equal", ->
      expect(Point(1, 1).isEqual(Point(1, 1))).toBe true
      expect(Point(1, 1).isEqual([1, 1])).toBe true
      expect(Point(1, 2).isEqual(Point(3, 3))).toBe false
      expect(Point(1, 2).isEqual([3, 3])).toBe false

  describe "::isPositive()", ->
    it "returns true if the point represents a forward traversal", ->
      expect(Point(-1, -1).isPositive()).toBe false
      expect(Point(-1, 0).isPositive()).toBe false
      expect(Point(-1, Infinity).isPositive()).toBe false
      expect(Point(0, 0).isPositive()).toBe false

      expect(Point(0, 1).isPositive()).toBe true
      expect(Point(5, 0).isPositive()).toBe true
      expect(Point(5, -1).isPositive()).toBe true

  describe "::isZero()", ->
    it "returns true if the point is zero", ->
      expect(Point(1, 1).isZero()).toBe false
      expect(Point(0, 1).isZero()).toBe false
      expect(Point(1, 0).isZero()).toBe false
      expect(Point(0, 0).isZero()).toBe true

  describe "::min(a, b)", ->
    it "returns the minimum of two points", ->
      expect(Point.min(Point(3, 4), Point(1, 1)).isEqual(Point(1, 1)))
      expect(Point.min(Point(1, 2), Point(5, 6)).isEqual(Point(1, 2)))
      expect(Point.min([3, 4], [1, 1]).isEqual([1, 1]))
      expect(Point.min([1, 2], [5, 6]).isEqual([1, 2]))

  describe "::max(a, b)", ->
    it "returns the minimum of two points", ->
      expect(Point.max(Point(3, 4), Point(1, 1)).isEqual(Point(3, 4)))
      expect(Point.max(Point(1, 2), Point(5, 6)).isEqual(Point(5, 6)))
      expect(Point.min([3, 4], [1, 1]).isEqual([3, 4]))
      expect(Point.min([1, 2], [5, 6]).isEqual([5, 6]))

  describe "::sanitizeNegatives()", ->
    it "returns the point so that it has valid buffer coordinates", ->
      expect(Point(-1, -1).sanitizeNegatives().isEqual(Point(0, 0)))
      expect(Point(-1, 0).sanitizeNegatives().isEqual(Point(0, 0)))
      expect(Point(-1, Infinity).sanitizeNegatives().isEqual(Point(0, 0)))

      expect(Point(5, -1).sanitizeNegatives().isEqual(Point(5, 0)))
      expect(Point(5, -Infinity).sanitizeNegatives().isEqual(Point(5, 0)))
      expect(Point(5, 5).sanitizeNegatives().isEqual(Point(5, 5)))

  describe "::traverse(delta)", ->
    it "returns a new point by traversing given rows and columns", ->
      expect(Point(2, 3).traverse(Point(0, 3)).isEqual(Point(2, 5)))
      expect(Point(2, 3).traverse([0, 3]).isEqual([2, 5]))

      expect(Point(1, 3).traverse(Point(4, 2)).isEqual([5, 2]))
      expect(Point(1, 3).traverse([5, 4]).isEqual([6, 4]))
