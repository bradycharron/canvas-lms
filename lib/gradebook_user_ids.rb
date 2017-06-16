#
# Copyright (C) 2017 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.

class GradebookUserIds
  def initialize(course, user)
    settings = (user.preferences.dig(:gradebook_settings, course.id) || {}).with_indifferent_access
    @course = course
    @include_inactive = settings[:show_inactive_enrollments] == "true"
    @include_concluded = settings[:show_concluded_enrollments] == "true"
    @column = settings[:sort_rows_by_column_id] || "student"
    @sort_by = settings[:sort_rows_by_setting_key] || "name"
    @selected_grading_period_id = settings.dig(:filter_columns_by, :grading_period_id)
    @selected_section_id = settings.dig(:filter_columns_by, :section_id)
    @direction = settings[:sort_rows_by_direction] || "ascending"
  end

  def user_ids
    if @column == "student"
      sort_by_student_name
    elsif @column&.include?("assignment")
      assignment_id = @column[/\d+$/]
      send("sort_by_assignment_#{@sort_by}", assignment_id)
    elsif @column == "total_grade"
      sort_by_total_grade
    else
      sort_by_student_name
    end
  end

  private

  def sort_by_student_name
    students.order_by_sortable_name(direction: @direction.to_sym).pluck(:id)
  end

  def sort_by_assignment_grade(assignment_id)
    student_enrollments_scope.
      joins("
        LEFT JOIN #{Submission.quoted_table_name}
          ON submissions.user_id = enrollments.user_id
          AND submissions.assignment_id = #{assignment_id}
      ").
      order("submissions.score #{sort_direction} NULLS LAST").
      pluck(:user_id).
      uniq
  end

  def sort_by_assignment_missing(assignment_id)
    all_user_ids = student_enrollments_scope.pluck(:user_id)
    user_ids_for_missing = Submission.missing.where(assignment_id: assignment_id, user_id: all_user_ids).pluck(:user_id)
    user_ids_for_missing.concat(all_user_ids).uniq
  end

  def sort_by_assignment_late(assignment_id)
    all_user_ids = student_enrollments_scope.pluck(:user_id)
    user_ids_for_late = Submission.late.where(assignment_id: assignment_id, user_id: all_user_ids).pluck(:user_id)
    user_ids_for_late.concat(all_user_ids).uniq
  end

  def sort_by_total_grade
    student_enrollments_scope.
      joins("
        LEFT JOIN #{Score.quoted_table_name}
          ON enrollments.id = scores.enrollment_id
          AND scores.grading_period_id #{grading_period_id ? "= #{grading_period_id}" : 'IS NULL'}
      ").
      order("scores.current_score #{sort_direction} NULLS LAST").
      pluck(:user_id).
      uniq
  end

  def student_enrollments_scope
    workflow_states = [:active, :invited]
    workflow_states << :inactive if @include_inactive
    workflow_states << :completed if @include_concluded
    student_enrollments = @course.enrollments.where(
      workflow_state: workflow_states,
      type: [:StudentEnrollment, :StudentViewEnrollment]
    )

    return student_enrollments.where(course_section_id: section_id) if section_id
    student_enrollments
  end

  def students
    User.where(id: student_enrollments_scope.select(:user_id))
  end

  def sort_direction
    @direction == "ascending" ? :asc : :desc
  end

  def grading_period_id
    return nil unless @course.grading_periods?
    return nil if @selected_grading_period_id == "0"

    if @selected_grading_period_id.nil? || @selected_grading_period_id == "null"
      GradingPeriod.current_period_for(@course)&.id
    else
      @selected_grading_period_id
    end
  end

  def section_id
    return nil if @selected_section_id.nil? || @selected_section_id == "null"
    @selected_section_id
  end
end
