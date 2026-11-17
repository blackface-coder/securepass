# code_serure

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Récupération du coffre

À la création du coffre, SecurePass génère une clé de récupération aléatoire
unique et l’affiche une seule fois. Conservez-la hors de l’application, en lieu
sûr : elle ne peut pas être recréée si elle est perdue. Seul son vérificateur
est conservé dans le stockage sécurisé de l’appareil.

Depuis l’écran de connexion, **Code principal oublié ?** permet de saisir cette
clé et de définir un nouveau code principal avec confirmation. Les entrées
restent dans le stockage sécurisé de l’appareil et ne sont chargées qu’après
validation du code principal ou de la clé de récupération. Si la clé est
absente ou perdue, **Réinitialiser le coffre** efface toutes les entrées après
une confirmation explicite. Les coffres créés avant l’ajout de la récupération
n’ont pas de clé configurée et doivent être réinitialisés s’ils ne peuvent pas
être déverrouillés.
