"""Tests for guest.py's trait resolution: which traits each package enables,
and which trait-gated dependencies are part of the build."""

import unittest

import guest


def manifest(traits, dependencies=()):
    """A `swift package dump-package` manifest with one target, "Library"."""
    return {
        "traits": [{"name": name, "enabledTraits": enables} for name, enables in traits.items()],
        "targets": [{"name": "Library", "dependencies": list(dependencies)}],
    }


def product(name, package, traits=None):
    """A product dependency, gated on `traits` when given."""
    condition = {"platformNames": [], "traits": traits} if traits else None
    return {"product": [name, package, None, condition]}


PACKAGE = manifest({
    "default": ["Logging"],
    "Logging": [],
    "Networking": ["Sockets"],
    "Sockets": [],
})


class DefaultTraitsTests(unittest.TestCase):

    def test_root_uses_defaults(self):
        self.assertEqual(guest.default_traits(PACKAGE), {"Logging"})
        self.assertEqual(guest.default_traits(PACKAGE, None), {"Logging"})

    def test_requested_default(self):
        self.assertEqual(guest.default_traits(PACKAGE, {"default"}), {"Logging"})

    def test_requested_traits_and_what_they_enable(self):
        self.assertEqual(guest.default_traits(PACKAGE, {"Networking"}), {"Networking", "Sockets"})

    def test_requested_traits_with_defaults(self):
        self.assertEqual(
            guest.default_traits(PACKAGE, {"default", "Networking"}),
            {"Logging", "Networking", "Sockets"},
        )

    def test_explicitly_empty(self):
        # `.package(..., traits: [])` turns the defaults off.
        self.assertEqual(guest.default_traits(PACKAGE, set()), set())

    def test_guest_disabled_traits_stay_off(self):
        package = manifest({"default": ["FloatingPointParsingShims"], "FloatingPointParsingShims": []})
        self.assertEqual(guest.default_traits(package), set())
        self.assertEqual(guest.default_traits(package, {"FloatingPointParsingShims"}), set())


class TraitDependencyTests(unittest.TestCase):

    PACKAGE = manifest(
        {"default": [], "Networking": []},
        [
            {"byName": ["Core", None]},
            product("Sockets", "SocketsPackage", traits=["Networking"]),
            {"target": ["Extras", {"platformNames": [], "traits": ["Networking"]}]},
        ],
    )

    def test_gated_dependencies_of_disabled_traits_are_left_out(self):
        disabled = guest.disabled_trait_dependencies(self.PACKAGE, set())
        self.assertEqual(disabled, {"Library": {"Sockets", "Extras"}})
        self.assertEqual(guest.enabled_trait_dependencies(self.PACKAGE, set()), {})

    def test_gated_dependencies_of_enabled_traits_are_added(self):
        self.assertEqual(guest.disabled_trait_dependencies(self.PACKAGE, {"Networking"}), {})
        self.assertEqual(
            guest.enabled_trait_dependencies(self.PACKAGE, {"Networking"}),
            {"Library": [("product", "Sockets"), ("target", "Extras")]},
        )

    def test_ungated_dependencies_are_untouched(self):
        for enabled in (set(), {"Networking"}):
            self.assertNotIn("Core", guest.disabled_trait_dependencies(self.PACKAGE, enabled).get("Library", set()))
            gated = guest.enabled_trait_dependencies(self.PACKAGE, enabled).get("Library", [])
            self.assertNotIn(("byName", "Core"), gated)


if __name__ == "__main__":
    unittest.main()
