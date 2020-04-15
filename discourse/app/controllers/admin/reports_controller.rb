# frozen_string_literal: true

class Admin::ReportsController < Admin::AdminController
  def index
    reports_methods = ['page_view_total_reqs'] +
      ApplicationRequest.req_types.keys
        .select { |r| r =~ /^page_view_/ && r !~ /mobile/ }
        .map { |r| r + "_reqs" } +
      Report.singleton_methods.grep(/^report_(?!about|storage_stats)/)

    reports = reports_methods.map do |name|
      type = name.to_s.gsub('report_', '')
      description = I18n.t("reports.#{type}.description", default: '')
      description_link = I18n.t("reports.#{type}.description_link", default: '')

      {
        type: type,
        title: I18n.t("reports.#{type}.title"),
        description: description.presence ? description : nil,
        description_link: description_link.presence ? description_link : nil
      }
    end

    render_json_dump(reports: reports.sort_by { |report| report[:title] })
  end

  def bulk
    reports = []

    hijack do
      params[:reports].each do |report_type, report_params|
        args = parse_params(report_params)

        report = nil
        if (report_params[:cache])
          report = Report.find_cached(report_type, args)
        end

        if report
          reports << report
        else
          report = Report.find(report_type, args)

          if (report_params[:cache]) && report
            Report.cache(report, 35.minutes)
          end

          if report.blank?
            report = Report._get(report_type, args)
            report.error = :not_found
          end

          reports << report
        end
      end

      render_json_dump(reports: reports)
    end
  end

  def show
    report_type = params[:type]

    raise Discourse::NotFound unless report_type =~ /^[a-z0-9\_]+$/

    args = parse_params(params)

    report = nil
    if (params[:cache])
      report = Report.find_cached(report_type, args)
    end

    if report
      return render_json_dump(report: report)
    end

    hijack do
      report = Report.find(report_type, args)

      raise Discourse::NotFound if report.blank?

      if (params[:cache])
        Report.cache(report, 35.minutes)
      end

      render_json_dump(report: report)
    end
  end

  private

  def parse_params(report_params)
    begin
      start_date = (report_params[:start_date].present? ? Time.parse(report_params[:start_date]).to_date : 1.days.ago).beginning_of_day
      end_date = (report_params[:end_date].present? ? Time.parse(report_params[:end_date]).to_date : start_date + 30.days).end_of_day
    rescue ArgumentError => e
      raise Discourse::InvalidParameters.new(e.message)
    end

    facets = nil
    if Array === report_params[:facets]
      facets = report_params[:facets].map { |s| s.to_s.to_sym }
    end

    limit = nil
    if report_params.has_key?(:limit) && report_params[:limit].to_i > 0
      limit = report_params[:limit].to_i
    end

    filters = nil
    if report_params.has_key?(:filters)
      filters = report_params[:filters]
    end

    {
      start_date: start_date,
      end_date: end_date,
      filters: filters,
      facets: facets,
      limit: limit
    }
  end
end
