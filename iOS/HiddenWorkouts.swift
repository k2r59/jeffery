import Foundation

/// Séances de Santé retirées de la liste de Jeffrey. HealthKit n'autorise une app qu'à effacer ses propres
/// enregistrements : celles écrites par l'app Exercice sont donc masquées ici, sans toucher à Santé.
enum HiddenWorkouts {
    private static let key = "pref.hiddenWorkouts"

    static var ids: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func hide(_ id: String) {
        var all = ids
        all.insert(id)
        UserDefaults.standard.set(Array(all), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
