Point = require "../src/point"

describe "Point", ->
  describe "::isPositive()", ->
    it "returns true if the point represents a forward traversal", ->
      expect(Point(-1, -1).isPositive()).toBe false
      expect(Point(-1, 0).isPositive()).toBe false
      expect(Point(-1, Infinity).isPositive()).toBe false
      expect(Point(0, 0).isPositive()).toBe false

      expect(Point(0, 1).isPositive()).toBe true
      expect(Point(5, 0).isPositive()).toBe true
      expect(Point(5, -1).isPositive()).toBe true
