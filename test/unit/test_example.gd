# Example gdUnit4 test suite demonstrating basic test patterns.
extends GdUnitTestSuite

func test_example_passes() -> void:
	assert_bool(true).is_true()

func test_example_equality() -> void:
	var expected := 42
	var actual := 40 + 2
	assert_int(actual).is_equal(expected)

func test_string_assertions() -> void:
	assert_str("Hello World").starts_with("Hello").ends_with("World")

func test_array_assertions() -> void:
	var items := ["apple", "banana", "cherry"]
	assert_array(items).has_size(3).contains(["banana"])
