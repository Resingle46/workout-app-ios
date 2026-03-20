import Foundation

enum SeedData {
    static func make() -> (categories: [ExerciseCategory], exercises: [Exercise], programs: [WorkoutProgram]) {
        let chest = ExerciseCategory(nameKey: "muscle.chest", symbol: "figure.strengthtraining.traditional")
        let back = ExerciseCategory(nameKey: "muscle.back", symbol: "figure.climbing")
        let legs = ExerciseCategory(nameKey: "muscle.legs", symbol: "figure.run")
        let shoulders = ExerciseCategory(nameKey: "muscle.shoulders", symbol: "figure.cooldown")
        let arms = ExerciseCategory(nameKey: "muscle.arms", symbol: "dumbbell")
        let core = ExerciseCategory(nameKey: "muscle.core", symbol: "figure.core.training")

        let categories = [chest, back, legs, shoulders, arms, core]
        let exercises = [
            Exercise(name: "Barbell Bench Press", categoryID: chest.id, equipment: "Barbell"),
            Exercise(name: "Incline Dumbbell Press", categoryID: chest.id, equipment: "Dumbbells"),
            Exercise(name: "Chest Fly", categoryID: chest.id, equipment: "Cable / Machine"),
            Exercise(name: "Push-Up", categoryID: chest.id, equipment: "Bodyweight"),
            Exercise(name: "Pull-Up", categoryID: back.id, equipment: "Bodyweight"),
            Exercise(name: "Lat Pulldown", categoryID: back.id, equipment: "Cable"),
            Exercise(name: "Barbell Row", categoryID: back.id, equipment: "Barbell"),
            Exercise(name: "Seated Cable Row", categoryID: back.id, equipment: "Cable"),
            Exercise(name: "Back Squat", categoryID: legs.id, equipment: "Barbell"),
            Exercise(name: "Romanian Deadlift", categoryID: legs.id, equipment: "Barbell"),
            Exercise(name: "Leg Press", categoryID: legs.id, equipment: "Machine"),
            Exercise(name: "Walking Lunges", categoryID: legs.id, equipment: "Dumbbells"),
            Exercise(name: "Overhead Press", categoryID: shoulders.id, equipment: "Barbell"),
            Exercise(name: "Lateral Raise", categoryID: shoulders.id, equipment: "Dumbbells"),
            Exercise(name: "Rear Delt Fly", categoryID: shoulders.id, equipment: "Cable / Dumbbells"),
            Exercise(name: "Arnold Press", categoryID: shoulders.id, equipment: "Dumbbells"),
            Exercise(name: "Barbell Curl", categoryID: arms.id, equipment: "Barbell"),
            Exercise(name: "Hammer Curl", categoryID: arms.id, equipment: "Dumbbells"),
            Exercise(name: "Triceps Pushdown", categoryID: arms.id, equipment: "Cable"),
            Exercise(name: "Skull Crusher", categoryID: arms.id, equipment: "EZ-bar"),
            Exercise(name: "Plank", categoryID: core.id, equipment: "Bodyweight"),
            Exercise(name: "Cable Crunch", categoryID: core.id, equipment: "Cable"),
            Exercise(name: "Hanging Leg Raise", categoryID: core.id, equipment: "Bodyweight"),
            Exercise(name: "Russian Twist", categoryID: core.id, equipment: "Bodyweight / Plate")
        ]

        let upper = WorkoutTemplate(
            title: "Upper A",
            focus: "Chest + Back + Arms",
            exercises: [
                WorkoutExerciseTemplate(exerciseID: exercises[0].id, sets: [8,8,6].map { WorkoutSetTemplate(reps: $0) }),
                WorkoutExerciseTemplate(exerciseID: exercises[6].id, sets: [10,10,8].map { WorkoutSetTemplate(reps: $0) }),
                WorkoutExerciseTemplate(exerciseID: exercises[17].id, sets: [12,12,12].map { WorkoutSetTemplate(reps: $0) }, groupKind: .superset, groupID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
                WorkoutExerciseTemplate(exerciseID: exercises[18].id, sets: [12,12,12].map { WorkoutSetTemplate(reps: $0) }, groupKind: .superset, groupID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
            ]
        )

        let lower = WorkoutTemplate(
            title: "Lower A",
            focus: "Legs + Core",
            exercises: [
                WorkoutExerciseTemplate(exerciseID: exercises[8].id, sets: [8,8,6].map { WorkoutSetTemplate(reps: $0) }),
                WorkoutExerciseTemplate(exerciseID: exercises[9].id, sets: [10,10,10].map { WorkoutSetTemplate(reps: $0) }),
                WorkoutExerciseTemplate(exerciseID: exercises[20].id, sets: [45,45,45].map { WorkoutSetTemplate(reps: $0) })
            ]
        )

        let program = WorkoutProgram(title: "Starter Program", workouts: [upper, lower])
        return (categories, exercises, [program])
    }
}
