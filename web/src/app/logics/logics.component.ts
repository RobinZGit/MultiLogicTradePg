import { Component, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { LogicsService } from '../services/logics.service';
import { LogicRow } from '../models/logic.model';
import {
  AppConfigService,
  apiConnectionErrorMessage,
} from '../services/app-config.service';

@Component({
  selector: 'app-logics',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './logics.component.html',
  styleUrl: './logics.component.css',
})
export class LogicsComponent implements OnInit {
  logics: LogicRow[] = [];
  loading = true;
  error: string | null = null;

  constructor(
    private readonly logicsService: LogicsService,
    private readonly appConfig: AppConfigService
  ) {}

  ngOnInit(): void {
    this.loadLogics();
  }

  loadLogics(): void {
    this.loading = true;
    this.error = null;
    this.logicsService.getLogics().subscribe({
      next: (rows) => {
        this.logics = rows;
        this.loading = false;
      },
      error: () => {
        this.error = apiConnectionErrorMessage(this.appConfig.apiUrl);
        this.loading = false;
      },
    });
  }

  accountTypeLabel(type: string): string {
    return type === 'fake' ? 'фейковый' : 'реальный';
  }
}
