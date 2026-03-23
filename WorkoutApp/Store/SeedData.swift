import Foundation

struct ExerciseSeedDefinition: Sendable {
    let name: String
    let categoryID: UUID
    let equipment: String
}

enum SeedData {
    static let chestCategoryID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
    static let backCategoryID = UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!
    static let legsCategoryID = UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!
    static let shouldersCategoryID = UUID(uuidString: "A1000000-0000-0000-0000-000000000004")!
    static let armsCategoryID = UUID(uuidString: "A1000000-0000-0000-0000-000000000005")!
    static let coreCategoryID = UUID(uuidString: "A1000000-0000-0000-0000-000000000006")!

    static let categories: [ExerciseCategory] = [
        ExerciseCategory(id: chestCategoryID, nameKey: "muscle.chest", symbol: "figure.strengthtraining.traditional"),
        ExerciseCategory(id: backCategoryID, nameKey: "muscle.back", symbol: "figure.climbing"),
        ExerciseCategory(id: legsCategoryID, nameKey: "muscle.legs", symbol: "figure.run"),
        ExerciseCategory(id: shouldersCategoryID, nameKey: "muscle.shoulders", symbol: "figure.cooldown"),
        ExerciseCategory(id: armsCategoryID, nameKey: "muscle.arms", symbol: "dumbbell"),
        ExerciseCategory(id: coreCategoryID, nameKey: "muscle.core", symbol: "figure.core.training")
    ]

    static let exerciseDefinitions: [ExerciseSeedDefinition] = [
        ExerciseSeedDefinition(name: "Barbell Bench Press", categoryID: chestCategoryID, equipment: "Barbell"),
        ExerciseSeedDefinition(name: "Incline Dumbbell Press", categoryID: chestCategoryID, equipment: "Dumbbells"),
        ExerciseSeedDefinition(name: "Chest Fly", categoryID: chestCategoryID, equipment: "Cable / Machine"),
        ExerciseSeedDefinition(name: "Push-Up", categoryID: chestCategoryID, equipment: "Bodyweight"),
        ExerciseSeedDefinition(name: "Incline Bench Press", categoryID: chestCategoryID, equipment: "Barbell / Bench"),
        ExerciseSeedDefinition(name: "Decline Bench Press", categoryID: chestCategoryID, equipment: "Barbell / Bench"),
        ExerciseSeedDefinition(name: "Chest Dip", categoryID: chestCategoryID, equipment: "Bodyweight / Dip Bars"),
        ExerciseSeedDefinition(name: "Machine Chest Press", categoryID: chestCategoryID, equipment: "Machine"),
        ExerciseSeedDefinition(name: "Pec Deck Fly", categoryID: chestCategoryID, equipment: "Machine"),
        ExerciseSeedDefinition(name: "Dumbbell Bench Press", categoryID: chestCategoryID, equipment: "Dumbbells / Bench"),

        ExerciseSeedDefinition(name: "Pull-Up", categoryID: backCategoryID, equipment: "Bodyweight"),
        ExerciseSeedDefinition(name: "Lat Pulldown", categoryID: backCategoryID, equipment: "Cable"),
        ExerciseSeedDefinition(name: "Barbell Row", categoryID: backCategoryID, equipment: "Barbell"),
        ExerciseSeedDefinition(name: "Seated Cable Row", categoryID: backCategoryID, equipment: "Cable"),
        ExerciseSeedDefinition(name: "Chin-Up", categoryID: backCategoryID, equipment: "Bodyweight / Pull-up Bar"),
        ExerciseSeedDefinition(name: "One Arm Dumbbell Row", categoryID: backCategoryID, equipment: "Dumbbell / Bench"),
        ExerciseSeedDefinition(name: "Face Pull", categoryID: backCategoryID, equipment: "Cable / Rope"),
        ExerciseSeedDefinition(name: "Straight Arm Pulldown", categoryID: backCategoryID, equipment: "Cable"),
        ExerciseSeedDefinition(name: "Deadlift", categoryID: backCategoryID, equipment: "Barbell"),

        ExerciseSeedDefinition(name: "Back Squat", categoryID: legsCategoryID, equipment: "Barbell"),
        ExerciseSeedDefinition(name: "Romanian Deadlift", categoryID: legsCategoryID, equipment: "Barbell"),
        ExerciseSeedDefinition(name: "Leg Press", categoryID: legsCategoryID, equipment: "Machine"),
        ExerciseSeedDefinition(name: "Walking Lunges", categoryID: legsCategoryID, equipment: "Dumbbells"),
        ExerciseSeedDefinition(name: "Front Squat", categoryID: legsCategoryID, equipment: "Barbell"),
        ExerciseSeedDefinition(name: "Bulgarian Split Squat", categoryID: legsCategoryID, equipment: "Dumbbells / Bench"),
        ExerciseSeedDefinition(name: "Leg Extension", categoryID: legsCategoryID, equipment: "Machine"),
        ExerciseSeedDefinition(name: "Seated Leg Curl", categoryID: legsCategoryID, equipment: "Machine"),
        ExerciseSeedDefinition(name: "Standing Calf Raise", categoryID: legsCategoryID, equipment: "Machine"),
        ExerciseSeedDefinition(name: "Hip Thrust", categoryID: legsCategoryID, equipment: "Barbell / Bench"),
        ExerciseSeedDefinition(name: "Step-Up", categoryID: legsCategoryID, equipment: "Dumbbells / Bench"),

        ExerciseSeedDefinition(name: "Overhead Press", categoryID: shouldersCategoryID, equipment: "Barbell"),
        ExerciseSeedDefinition(name: "Lateral Raise", categoryID: shouldersCategoryID, equipment: "Dumbbells"),
        ExerciseSeedDefinition(name: "Rear Delt Fly", categoryID: shouldersCategoryID, equipment: "Cable / Dumbbells"),
        ExerciseSeedDefinition(name: "Arnold Press", categoryID: shouldersCategoryID, equipment: "Dumbbells"),
        ExerciseSeedDefinition(name: "Seated Dumbbell Press", categoryID: shouldersCategoryID, equipment: "Dumbbells / Bench"),
        ExerciseSeedDefinition(name: "Front Raise", categoryID: shouldersCategoryID, equipment: "Dumbbells"),
        ExerciseSeedDefinition(name: "Upright Row", categoryID: shouldersCategoryID, equipment: "Barbell"),
        ExerciseSeedDefinition(name: "Reverse Pec Deck", categoryID: shouldersCategoryID, equipment: "Machine"),
        ExerciseSeedDefinition(name: "Push Press", categoryID: shouldersCategoryID, equipment: "Barbell"),
        ExerciseSeedDefinition(name: "Cable Lateral Raise", categoryID: shouldersCategoryID, equipment: "Cable"),

        ExerciseSeedDefinition(name: "Barbell Curl", categoryID: armsCategoryID, equipment: "Barbell"),
        ExerciseSeedDefinition(name: "Hammer Curl", categoryID: armsCategoryID, equipment: "Dumbbells"),
        ExerciseSeedDefinition(name: "Triceps Pushdown", categoryID: armsCategoryID, equipment: "Cable"),
        ExerciseSeedDefinition(name: "Skull Crusher", categoryID: armsCategoryID, equipment: "EZ-bar"),
        ExerciseSeedDefinition(name: "Incline Dumbbell Curl", categoryID: armsCategoryID, equipment: "Dumbbells / Bench"),
        ExerciseSeedDefinition(name: "Preacher Curl", categoryID: armsCategoryID, equipment: "EZ-bar / Bench"),
        ExerciseSeedDefinition(name: "Concentration Curl", categoryID: armsCategoryID, equipment: "Dumbbell / Bench"),
        ExerciseSeedDefinition(name: "Close Grip Bench Press", categoryID: armsCategoryID, equipment: "Barbell / Bench"),
        ExerciseSeedDefinition(name: "Overhead Dumbbell Triceps Extension", categoryID: armsCategoryID, equipment: "Dumbbell"),
        ExerciseSeedDefinition(name: "Bench Dip", categoryID: armsCategoryID, equipment: "Bodyweight / Bench"),
        ExerciseSeedDefinition(name: "Cable Curl", categoryID: armsCategoryID, equipment: "Cable"),

        ExerciseSeedDefinition(name: "Plank", categoryID: coreCategoryID, equipment: "Bodyweight"),
        ExerciseSeedDefinition(name: "Cable Crunch", categoryID: coreCategoryID, equipment: "Cable"),
        ExerciseSeedDefinition(name: "Hanging Leg Raise", categoryID: coreCategoryID, equipment: "Bodyweight"),
        ExerciseSeedDefinition(name: "Russian Twist", categoryID: coreCategoryID, equipment: "Bodyweight / Plate"),
        ExerciseSeedDefinition(name: "Crunch", categoryID: coreCategoryID, equipment: "Bodyweight"),
        ExerciseSeedDefinition(name: "Hanging Knee Raise", categoryID: coreCategoryID, equipment: "Bodyweight / Pull-up Bar"),
        ExerciseSeedDefinition(name: "Ab Wheel Rollout", categoryID: coreCategoryID, equipment: "Ab Wheel"),
        ExerciseSeedDefinition(name: "Bicycle Crunch", categoryID: coreCategoryID, equipment: "Bodyweight"),
        ExerciseSeedDefinition(name: "Sit-Up", categoryID: coreCategoryID, equipment: "Bodyweight"),
        ExerciseSeedDefinition(name: "Dead Bug", categoryID: coreCategoryID, equipment: "Bodyweight"),
        ExerciseSeedDefinition(name: "Mountain Climber", categoryID: coreCategoryID, equipment: "Bodyweight")
    ]

    static func definition(forExerciseNamed name: String) -> ExerciseSeedDefinition? {
        exerciseDefinitions.first { $0.name == name }
    }

    static func make() -> (categories: [ExerciseCategory], exercises: [Exercise], programs: [WorkoutProgram]) {
        let exercises = exerciseDefinitions.map {
            Exercise(name: $0.name, categoryID: $0.categoryID, equipment: $0.equipment)
        }

        let exerciseByName = Dictionary(uniqueKeysWithValues: exercises.map { ($0.name, $0) })

        let upper = WorkoutTemplate(
            title: "Upper A",
            focus: "Chest + Back + Arms",
            exercises: [
                WorkoutExerciseTemplate(exerciseID: exercise(named: "Barbell Bench Press", in: exerciseByName).id, sets: [8, 8, 6].map { WorkoutSetTemplate(reps: $0) }),
                WorkoutExerciseTemplate(exerciseID: exercise(named: "Barbell Row", in: exerciseByName).id, sets: [10, 10, 8].map { WorkoutSetTemplate(reps: $0) }),
                WorkoutExerciseTemplate(exerciseID: exercise(named: "Hammer Curl", in: exerciseByName).id, sets: [12, 12, 12].map { WorkoutSetTemplate(reps: $0) }, groupKind: .superset, groupID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
                WorkoutExerciseTemplate(exerciseID: exercise(named: "Triceps Pushdown", in: exerciseByName).id, sets: [12, 12, 12].map { WorkoutSetTemplate(reps: $0) }, groupKind: .superset, groupID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
            ]
        )

        let lower = WorkoutTemplate(
            title: "Lower A",
            focus: "Legs + Core",
            exercises: [
                WorkoutExerciseTemplate(exerciseID: exercise(named: "Back Squat", in: exerciseByName).id, sets: [8, 8, 6].map { WorkoutSetTemplate(reps: $0) }),
                WorkoutExerciseTemplate(exerciseID: exercise(named: "Romanian Deadlift", in: exerciseByName).id, sets: [10, 10, 10].map { WorkoutSetTemplate(reps: $0) }),
                WorkoutExerciseTemplate(exerciseID: exercise(named: "Plank", in: exerciseByName).id, sets: [45, 45, 45].map { WorkoutSetTemplate(reps: $0) })
            ]
        )

        let program = WorkoutProgram(title: "Starter Program", workouts: [upper, lower])
        return (categories, exercises, [program])
    }

    private static func exercise(named name: String, in exerciseByName: [String: Exercise]) -> Exercise {
        guard let exercise = exerciseByName[name] else {
            fatalError("Missing seed exercise named \(name)")
        }
        return exercise
    }
}
